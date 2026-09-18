// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ChessEngine} from "./libraries/ChessEngine.sol";
import {PositionHash} from "./libraries/PositionHash.sol";

/// @dev Deliberately minimal (not OpenZeppelin's IERC20) -- only the two functions this
/// contract ever calls, to avoid pulling in ABI surface we don't use. No SafeERC20 wrapper
/// either (bytecode budget, see the contract's own size-constraint note); a plain call that
/// returns false reverts explicitly below, and a token whose call reverts outright propagates
/// that revert unchanged. `allowedTokens` on the factory is the actual line of defense against
/// non-standard tokens (fee-on-transfer, rebasing, missing bool return) -- see
/// ChessGameFactory.setTokenAllowed's NatSpec.
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice One instance = one game table, deployed as an EIP-1167 minimal proxy clone of a
/// single implementation via ChessGameFactory. Every move is validated fully on-chain.
/// Checkmate/stalemate claims are verified atomically via ChessEngine.hasLegalMove() at claim
/// time -- no optimistic dispute window, no separate finalization step.
/// @dev Clones share the implementation's bytecode via delegatecall and do NOT run its
/// constructor, so every per-table parameter that would otherwise be `immutable` in a
/// non-clone deployment is instead regular storage set once via `initialize`, guarded by
/// OpenZeppelin's `Initializable`.
/// @dev All revert reasons are custom errors, not require-strings: the deployed runtime
/// bytecode was 24879 bytes, over the EIP-170 24576-byte contract-size limit enforced by
/// every real EVM chain (including Polygon). Custom errors cost a 4-byte selector per call
/// site instead of a full string + ABI encoding, which is what brings the contract back
/// under the limit without touching optimizer settings or trimming functionality.
contract ChessGameTable is Initializable {
    error NotAPlayer();
    error GameNotActive();
    error PlayersMustDiffer();
    error DuelMoveTimeoutOutOfRange();
    error CrowdPlayersMustBeUnset();
    error CrowdMoveTimeoutInvalid();
    error BaseStakeMustBePositive();
    error RampPlyOutOfRange();
    error StakeWouldNeverGrow();
    error AtLeastOneCommittedPlayerRequired();
    error PendingTakebackMustResolveFirst();
    error PendingStakeIncreaseMustResolveFirst();
    error NotYourTurn();
    error WalletLockedToOtherColor();
    error WrongStakeAmount();
    error IllegalMove();
    error NoMoveToTakeBack();
    error TakebackAlreadyProposed();
    error NoPendingTakebackProposal();
    error OnlyOpponentCanAcceptTakeback();
    error NoSnapshotAvailable();
    error OnlyOpponentCanRejectTakeback();
    error StakeIncreaseNotSupported();
    error MustBeStrictIncrease();
    error StakeIncreaseAlreadyProposed();
    error UseVoteStakeIncreaseInstead();
    error NoPendingStakeIncreaseProposal();
    error OnlyOpponentCanAcceptStakeIncrease();
    error UseCancelStakeIncreaseVoteInstead();
    error OnlyOpponentCanRejectStakeIncrease();
    error VotingOnlyForCrowd();
    error AlreadyVotedOnThisProposal();
    error CancelVoteOnlyForCrowd();
    error VoteWindowStillOpen();
    error TakebackNotSupported();
    error GroupProposalAlreadyActive();
    error NoPendingGroupProposal();
    error PendingGroupProposalMustResolveFirst();
    error OnlyLastMoverMayClaim();
    error SideToMoveNotInCheck();
    error SideToMoveInCheckUseCheckmate();
    error NotActuallyCheckmate();
    error NotActuallyStalemate();
    error FiftyMoveRuleNotReached();
    error RepetitionThresholdNotReached();
    error ResignOnlyForDuel();
    error OpponentSeatVacant();
    error NoMoveTimeoutConfigured();
    error MoveTimeoutNotReached();
    error DuelSettlesViaWithdraw();
    error GameNotFinishedYet();
    error NotAContributor();
    error AlreadyClaimedShare();
    error NothingToWithdraw();
    error WithdrawTransferFailed();
    error ClosedProposalWindowStillOpen();
    error StakeTransferFailed();

    // ---------- protocol-wide constants (identical for every table by design) ----------

    uint8 public constant MAX_STAKE_MULTIPLIER = 10;
    uint32 public constant MIN_RAMP_PLY = 20;
    uint32 public constant MAX_RAMP_PLY = 9999;

    // Polygon PoS can have short reorgs, which matters for timestamp-gated irreversible
    // claims/payouts. No dedicated confirmation-block mechanism is needed: every
    // timestamp-gated window in this contract (MIN_MOVE_TIMEOUT, MIN_MOVE_TIMEOUT-as-
    // dispute-window-floor, GROUP_VOTE_WINDOW) is bounded at 5+ minutes, many times longer
    // than a realistic Polygon reorg depth (low single-digit blocks, ~2s each). The
    // move-count-gated claims (fifty-move rule, threefold repetition) don't depend on
    // block.timestamp at all, so reorg timing is structurally irrelevant to them. A literal
    // N-block delay would have added storage, new checks across several claim functions,
    // and deployed-bytecode weight for negligible additional safety margin on top of what
    // the existing window floors already provide — not worth spending part of the EIP-170
    // size budget on. No `CONFIRMATION_BLOCKS` constant is defined.

    uint16 public constant FIFTY_MOVE_HALFMOVES = 100; // claimable by a player
    uint8 public constant THREEFOLD_COUNT = 3; // claimable by a player

    /// @notice Hard ceiling for `referralFeeBps` (below), same shape as the factory's
    /// MAX_PROTOCOL_FEE_BPS: whoever calls the factory's create*Table functions picks their own
    /// rate for their own table, up to this cap. Not a single protocol-wide constant anymore --
    /// the rate a specific table charges is always readable on that table's own storage (and
    /// shown in its UI) before anyone deposits into it, so trust comes from transparency rather
    /// than a fixed global rate.
    uint16 public constant MAX_REFERRAL_FEE_BPS = 500; // 5% hard ceiling, enforced by the factory

    /// @notice moveTimeout's only purpose is anti-abandonment protection for closed tables:
    /// it is not a pacing/blitz clock — that role belongs to the progressive stake curve.
    /// On-chain timestamps aren't second-precise (validator latitude + block interval), and
    /// a real player needs a fair chance to notice it's their turn and submit a move, so any
    /// nonzero moveTimeout is bounded to [MIN_MOVE_TIMEOUT, MAX_MOVE_TIMEOUT]. The upper
    /// bound deliberately allows a correspondence-style table (up to 7 days/move), while the
    /// lower bound still comfortably clears the reorg-safety floor described above. Crowd
    /// tables may still set moveTimeout = 0 (no idle-move timer needed because anyone can
    /// step in); MIN_MOVE_TIMEOUT doubles as the checkmate/stalemate dispute window fallback
    /// for that zero-timeout case only, since a dispute window must never be zero-length.
    uint32 public constant MIN_MOVE_TIMEOUT = 5 minutes;
    uint32 public constant MAX_MOVE_TIMEOUT = 7 days;

    enum Status {
        Active,
        Finished
    }

    enum Result {
        None,
        WhiteWon,
        BlackWon,
        Draw
    }

    enum Mode {
        Duel,
        Crowd
    }

    enum Color {
        None,
        White,
        Black
    }

    enum StakeCurve {
        Linear,
        Compound,
        Flat // no growth at all: every move costs exactly baseStake for the whole game
    }

    struct Snapshot {
        uint256 board;
        uint8 castlingRights;
        uint8 enPassantSquare;
        bool whiteToMove;
        uint16 halfmoveClock;
        uint32 plyCount;
        uint256 currentStake;
        bool valid;
    }

    // ---------- table configuration (storage, not immutable, so each EIP-1167 clone can hold its own values) ----------

    Mode public mode;
    /// @notice address(0) = native currency (POL on Polygon); any other value is an ERC20 token
    /// address, set once in initialize() and never changed. Every stake, fee and payout for
    /// this table moves in this same currency -- no swaps, no oracle, no cross-token
    /// bookkeeping on-chain.
    address public token;
    address public whitePlayer; // Crowd mode: always address(0); use colorOf instead
    address public blackPlayer;
    uint256 public baseStake;
    uint32 public rampPly;
    uint32 public moveTimeout; // seconds; mandatory (>0) for Duel tables, may be 0 for Crowd tables
    StakeCurve public curve;
    uint256 public compoundRateBps; // only meaningful when curve == Compound

    address public protocolFeeRecipient; // copied from the factory at creation time
    uint16 public protocolFeeBps; // copied from the factory at creation time; frozen for this table's life
    address public frontendRecipient; // whichever UI created this table, for referralFeeBps
    // Set once by whoever called the factory's create*Table function, capped at
    // MAX_REFERRAL_FEE_BPS, frozen for this table's life -- same frozen-at-creation shape as
    // protocolFeeBps, just chosen by the integrator instead of the protocol owner.
    uint16 public referralFeeBps;

    // ---------- mutable game state ----------

    Status public status;
    Result public result;

    uint256 public board;
    uint8 public castlingRights;
    uint8 public enPassantSquare;
    bool public whiteToMove;
    uint16 public halfmoveClock;
    uint32 public plyCount;
    uint256 public currentStake;
    uint256 public pot;
    uint64 public lastMoveTimestamp;

    mapping(bytes32 => uint8) public positionCounts;

    Snapshot private prevSnapshot;
    address public takebackProposer;

    // ---------- Crowd-mode contribution tracking ----------

    mapping(address => Color) public colorOf;
    mapping(address => uint256) public contribution;
    uint256 public totalWhiteContribution;
    uint256 public totalBlackContribution;
    mapping(address => bool) public hasClaimedShare;
    uint256 public whitePotShare;
    uint256 public blackPotShare;
    bool public sharesFinalized;

    // ---------- stake-increase: two-party consensus (Duel) OR weighted vote (Crowd) ----------

    address public stakeIncreaseProposer;
    uint256 public proposedBaseStake;

    // ---------- Duel two-party proposal timeout ----------
    // Shared by BOTH takebackProposer and stakeIncreaseProposer -- safe because the two are
    // mutually exclusive by construction (proposeTakeback/proposeStakeIncrease each refuse to
    // start while the OTHER kind is already pending), so at most one proposal, and therefore at
    // most one live deadline, ever exists at a time. Set fresh every time either propose*
    // function starts a new Duel proposal. Read by cancelTakeback/cancelStakeIncrease: the
    // proposer themselves may cancel their own proposal at any time (no reason to make them wait
    // out a clock they themselves could just let expire); anyone else must wait until this
    // deadline passes, mirroring Crowd's groupProposalDeadline/cancelGroupProposal. Without
    // this, an unresponsive opponent after a propose* call freezes the whole pot forever --
    // claimTimeoutVictory() explicitly refuses to fire while either proposer field is set.
    uint64 public closedProposalDeadline;

    // ---------- Crowd weighted group votes: stake-increase OR takeback ----------
    // Duel keeps its separate two-party mechanisms above/below entirely untouched. `groupProposer`
    // is the single flag for "is a Crowd vote pending" across BOTH kinds -- at most one can be
    // active at a time, which `makeMove`'s guard enforces. Vote weight = `contribution[addr]`, frozen
    // for the vote's duration because the only place `contribution`/`totalWhiteContribution`/
    // `totalBlackContribution` change is `makeMove`, itself blocked while `groupProposer != address(0)`
    // -- no separate snapshot needed. `groupProposalId` + `lastVotedGroupProposalId` (instead of a
    // plain `mapping(address=>bool)`) prevents a stale vote on a past, already-resolved proposal from
    // being misread as a vote on a brand new one.
    enum ProposalKind {
        None,
        StakeIncrease,
        Takeback
    }

    uint32 public constant GROUP_VOTE_WINDOW = 24 hours;
    address public groupProposer;
    ProposalKind public groupProposalKind;
    uint256 public groupProposedValue; // newBaseStake for StakeIncrease; unused (0) for Takeback
    uint256 public groupProposalId;
    mapping(address => uint256) public lastVotedGroupProposalId;
    uint256 public yesWeightWhite;
    uint256 public yesWeightBlack;
    // Cumulative weight (yes + no together) that has voted on the CURRENT groupProposalId, per
    // side. Lets voteOnGroupProposal prove a side mathematically dead -- see its own comment.
    uint256 public votedWeightWhite;
    uint256 public votedWeightBlack;
    uint64 public groupProposalDeadline;

    /// @notice The address that made the most recent move, for ALL modes. Needed so a Crowd
    /// takeback vote can refund the exact payer of the undone move -- unlike Duel, where the
    /// mover is always derivable from color (`whitePlayer`/`blackPlayer`), Crowd allows
    /// different addresses to have played the same color across different plies.
    address public lastMover;

    // ---------- events ----------

    event MoveMade(address indexed mover, uint8 from, uint8 to, uint8 promotion, uint256 stakePaid);
    event GameFinished(Result result, address indexed triggeredBy);
    event TakebackProposed(address indexed proposer);
    event TakebackAccepted(address indexed proposer, address indexed accepter, uint256 refunded);
    event TakebackRejected(address indexed accepter);
    // `byProposer=true` when the proposer cancelled their own still-pending proposal early;
    // `false` when anyone cleaned up an abandoned one after closedProposalDeadline passed.
    event TakebackCancelled(address indexed proposer, bool byProposer);
    event ShareClaimed(address indexed contributor, uint256 amount);
    event StakeIncreaseProposed(address indexed proposer, uint256 newBaseStake);
    event StakeIncreaseAccepted(uint256 newBaseStake);
    event StakeIncreaseRejected(uint256 rejectedBaseStake);
    event StakeIncreaseCancelled(address indexed proposer, uint256 rejectedBaseStake, bool byProposer);
    event GroupProposalVoteCast(address indexed voter, bool support, uint256 weight);
    // `deadlocked=true` when auto-cancelled inside voteOnGroupProposal because a side became
    // mathematically incapable of reaching >50% (see that function); `false` for the pre-existing
    // 24h-timeout path through cancelGroupProposal().
    event GroupProposalCancelled(ProposalKind kind, uint256 value, bool deadlocked);

    modifier onlyPlayer() {
        if (mode == Mode.Duel) {
            if (msg.sender != whitePlayer && msg.sender != blackPlayer) revert NotAPlayer();
        } else {
            if (colorOf[msg.sender] == Color.None) revert NotAPlayer();
        }
        _;
    }

    modifier onlyActive() {
        if (status != Status.Active) revert GameNotActive();
        _;
    }

    /// @dev A Duel table created as a public challenge (one side still address(0)) must block
    /// resign()/proposeTakeback()/proposeStakeIncrease() until the vacancy is filled: each of
    /// those eventually reads "the other player" as whitePlayer/blackPlayer, and a still-vacant
    /// address(0) there means the funds get credited to nobody (resign) or nobody can ever
    /// accept/reject (takeback/stakeIncrease) -- the latter permanently deadlocks the table,
    /// since claimTimeoutVictory is itself blocked while one of those proposals is pending on a
    /// Duel table. No-op for Crowd (mode check short-circuits) and for an already-filled
    /// Duel table (both addresses nonzero).
    modifier duelSeatsFilled() {
        if (mode == Mode.Duel && (whitePlayer == address(0) || blackPlayer == address(0))) {
            revert OpponentSeatVacant();
        }
        _;
    }

    /// @dev Runs only on the implementation contract deployed by the factory's constructor;
    /// clones never execute this because EIP-1167 delegatecalls into the implementation's
    /// runtime code without ever running its constructor.
    constructor() {
        _disableInitializers();
    }

    function initialize(
        Mode _mode,
        address _white,
        address _black,
        uint256 _baseStake,
        uint32 _rampPly,
        uint32 _moveTimeout,
        StakeCurve _curve,
        address _protocolFeeRecipient,
        uint16 _protocolFeeBps,
        address _frontendRecipient,
        uint16 _referralFeeBps,
        address _token
    ) external initializer {
        if (_mode == Mode.Duel) {
            // A single address(0) side is a public 1v1 challenge: the vacancy is permanently
            // claimed by whoever moves first for that color (see `makeMove`), after which the
            // table is indistinguishable from an ordinary two-real-address Duel game -- resign/
            // takeback/stakeIncrease already key off whitePlayer/blackPlayer directly, so they
            // work automatically once filled. Both sides zero (no committed player at all) is
            // still rejected.
            if (_white == address(0) && _black == address(0)) revert AtLeastOneCommittedPlayerRequired();
            if (_white == _black) revert PlayersMustDiffer(); // only reachable when both are the same nonzero address
            if (_moveTimeout < MIN_MOVE_TIMEOUT || _moveTimeout > MAX_MOVE_TIMEOUT) {
                revert DuelMoveTimeoutOutOfRange();
            }
            whitePlayer = _white;
            blackPlayer = _black;
        } else {
            if (_white != address(0) || _black != address(0)) revert CrowdPlayersMustBeUnset();
            if (_moveTimeout != 0 && (_moveTimeout < MIN_MOVE_TIMEOUT || _moveTimeout > MAX_MOVE_TIMEOUT)) {
                revert CrowdMoveTimeoutInvalid();
            }
        }
        if (_baseStake == 0) revert BaseStakeMustBePositive();
        if (_rampPly < MIN_RAMP_PLY || _rampPly > MAX_RAMP_PLY) revert RampPlyOutOfRange();
        // Flat is exempt: a stake that never grows is the entire point of this curve, not the
        // degenerate Linear/Compound edge case (baseStake too small relative to rampPly) this
        // check exists to catch. rampPly is still validated above for a consistent create-table
        // interface across all three curves, even though Flat never actually uses it.
        if (_curve != StakeCurve.Flat && (_baseStake * (MAX_STAKE_MULTIPLIER - 1)) / _rampPly == 0) {
            revert StakeWouldNeverGrow();
        }

        mode = _mode;
        token = _token;
        baseStake = _baseStake;
        rampPly = _rampPly;
        moveTimeout = _moveTimeout;
        curve = _curve;
        protocolFeeRecipient = _protocolFeeRecipient;
        protocolFeeBps = _protocolFeeBps;
        frontendRecipient = _frontendRecipient;
        referralFeeBps = _referralFeeBps;

        if (_curve == StakeCurve.Compound) {
            compoundRateBps = _computeCompoundRateBps(_rampPly);
        }

        board = _initialBoard();
        castlingRights = ChessEngine.WK | ChessEngine.WQ | ChessEngine.BK | ChessEngine.BQ;
        enPassantSquare = ChessEngine.NO_EN_PASSANT;
        whiteToMove = true;
        halfmoveClock = 0;
        plyCount = 0;
        currentStake = _baseStake;
        status = Status.Active;
        lastMoveTimestamp = uint64(block.timestamp);
        positionCounts[_currentHash()] = 1;
    }

    function _initialBoard() private pure returns (uint256) {
        uint256 b = 0;
        uint8[8] memory backRank = [
            ChessEngine.ROOK,
            ChessEngine.KNIGHT,
            ChessEngine.BISHOP,
            ChessEngine.QUEEN,
            ChessEngine.KING,
            ChessEngine.BISHOP,
            ChessEngine.KNIGHT,
            ChessEngine.ROOK
        ];
        for (uint8 f = 0; f < 8; f++) {
            b = ChessEngine.setPiece(b, f, backRank[f]);
            b = ChessEngine.setPiece(b, 8 + f, ChessEngine.PAWN);
            b = ChessEngine.setPiece(b, 48 + f, ChessEngine.PAWN | ChessEngine.BLACK_FLAG);
            b = ChessEngine.setPiece(b, 56 + f, backRank[f] | ChessEngine.BLACK_FLAG);
        }
        return b;
    }

    function _currentHash() internal view returns (bytes32) {
        return PositionHash.hash(board, castlingRights, enPassantSquare, whiteToMove);
    }

    // ---------- compound stake curve ----------

    /// @dev One-time, bounded computation at table creation: binary search (fixed 40
    /// iterations) for the smallest per-move bps rate `r` such that (1+r)^rampPly >= 10x.
    /// `_powWadCapped` caps intermediate results well below 10x's target so a large `r`
    /// tested against a large `rampPly` can never approach uint256 overflow.
    function _computeCompoundRateBps(uint32 _rampPly) private pure returns (uint256) {
        uint256 lo = 1;
        uint256 hi = 5000; // 50% per move ceiling; (1.5)^rampPly already vastly exceeds 10x
        // for every allowed rampPly, so this upper bound is always sufficient.
        for (uint8 iter = 0; iter < 40; iter++) {
            uint256 mid = (lo + hi) / 2;
            uint256 baseWad = 1e18 + (mid * 1e18) / 10000;
            uint256 grown = _powWadCapped(baseWad, _rampPly, 1000e18);
            if (grown < 10e18) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return hi;
    }

    /// @dev Computes baseWad^n in fixed-point (1e18 = 1.0), stopping early once the result
    /// reaches `cap`. The cap is chosen far above the 10x target but far below any value
    /// that could overflow on the next multiplication, so no iteration can overflow.
    function _powWadCapped(uint256 baseWad, uint32 n, uint256 cap) private pure returns (uint256) {
        uint256 grown = 1e18;
        for (uint32 i = 0; i < n; i++) {
            grown = (grown * baseWad) / 1e18;
            if (grown >= cap) return cap;
        }
        return grown;
    }

    // ---------- core move ----------

    function makeMove(uint8 from, uint8 to, uint8 promotion) external payable onlyActive {
        if (takebackProposer != address(0)) revert PendingTakebackMustResolveFirst();
        if (stakeIncreaseProposer != address(0)) revert PendingStakeIncreaseMustResolveFirst();
        if (groupProposer != address(0)) revert PendingGroupProposalMustResolveFirst();

        bool moverWasWhite = whiteToMove;
        if (mode == Mode.Duel) {
            address mover = moverWasWhite ? whitePlayer : blackPlayer;
            if (mover == address(0)) {
                // Public 1v1 challenge: the vacant side is permanently claimed by whoever moves
                // first for it.
                address other = moverWasWhite ? blackPlayer : whitePlayer;
                if (msg.sender == other) revert WalletLockedToOtherColor();
                if (moverWasWhite) {
                    whitePlayer = msg.sender;
                } else {
                    blackPlayer = msg.sender;
                }
            } else if (msg.sender != mover) {
                revert NotYourTurn();
            }
        } else {
            Color currentColor = moverWasWhite ? Color.White : Color.Black;
            Color locked = colorOf[msg.sender];
            if (locked == Color.None) {
                colorOf[msg.sender] = currentColor;
            } else if (locked != currentColor) {
                revert WalletLockedToOtherColor();
            }
        }
        // Native tables must send exactly currentStake as msg.value; token tables must send none
        // (the actual ERC20 pull happens last, after all state effects -- see the transferFrom
        // call near the end of this function for why).
        if (token == address(0)) {
            if (msg.value != currentStake) revert WrongStakeAmount();
        } else {
            if (msg.value != 0) revert WrongStakeAmount();
        }
        uint256 stakePaid = currentStake; // amount actually owed this move, native or token alike

        ChessEngine.Position memory pos = ChessEngine.Position({
            board: board, castlingRights: castlingRights, enPassantSquare: enPassantSquare, whiteToMove: whiteToMove
        });
        (bool legal, ChessEngine.MoveResult memory mr) = ChessEngine.isLegalMove(pos, from, to, promotion);
        if (!legal) revert IllegalMove();

        // snapshot pre-move state for a possible single-ply takeback
        prevSnapshot = Snapshot({
            board: board,
            castlingRights: castlingRights,
            enPassantSquare: enPassantSquare,
            whiteToMove: whiteToMove,
            halfmoveClock: halfmoveClock,
            plyCount: plyCount,
            currentStake: currentStake,
            valid: true
        });

        board = mr.board;
        castlingRights = mr.castlingRights;
        enPassantSquare = mr.enPassantSquare;
        whiteToMove = !whiteToMove;
        halfmoveClock = (mr.isCapture || mr.isPawnMove) ? 0 : halfmoveClock + 1;
        plyCount += 1;
        pot += stakePaid;

        positionCounts[_currentHash()] += 1;

        if (mode == Mode.Crowd) {
            contribution[msg.sender] += stakePaid;
            if (moverWasWhite) {
                totalWhiteContribution += stakePaid;
            } else {
                totalBlackContribution += stakePaid;
            }
        }

        uint256 cap = baseStake * MAX_STAKE_MULTIPLIER;
        uint256 next;
        if (curve == StakeCurve.Flat) {
            next = currentStake; // always stays at baseStake -- no progressive pressure at all
        } else if (curve == StakeCurve.Linear) {
            uint256 increment = (baseStake * (MAX_STAKE_MULTIPLIER - 1)) / rampPly;
            next = currentStake + increment;
        } else {
            next = (currentStake * (10000 + compoundRateBps)) / 10000;
        }
        currentStake = next > cap ? cap : next;

        lastMoveTimestamp = uint64(block.timestamp);
        lastMover = msg.sender;

        // Checks-effects-interactions: every state effect for this move is already applied
        // above, so a reentrant call triggered by a hook on a malicious (mistakenly allowlisted)
        // token can only ever see fully-consistent post-move state, never a half-applied move.
        if (token != address(0)) {
            if (!IERC20(token).transferFrom(msg.sender, address(this), stakePaid)) revert StakeTransferFailed();
        }

        emit MoveMade(msg.sender, from, to, promotion, stakePaid);
    }

    // ---------- consent-based single-ply takeback (Duel tables only) ----------

    function proposeTakeback() external onlyActive onlyPlayer duelSeatsFilled {
        if (mode != Mode.Duel && mode != Mode.Crowd) revert TakebackNotSupported();
        if (!prevSnapshot.valid) revert NoMoveToTakeBack();
        // Symmetric with proposeStakeIncrease's existing takebackProposer check below -- keeps
        // the two Duel proposal kinds strictly mutually exclusive, which closedProposalDeadline
        // relies on (see its declaration).
        if (stakeIncreaseProposer != address(0)) revert PendingStakeIncreaseMustResolveFirst();

        if (mode == Mode.Duel) {
            if (takebackProposer != address(0)) revert TakebackAlreadyProposed();
            takebackProposer = msg.sender;
            closedProposalDeadline = uint64(block.timestamp) + GROUP_VOTE_WINDOW;
        } else {
            if (groupProposer != address(0)) revert GroupProposalAlreadyActive();
            groupProposer = msg.sender;
            groupProposalKind = ProposalKind.Takeback;
            groupProposedValue = 0;
            groupProposalId += 1;
            yesWeightWhite = 0;
            yesWeightBlack = 0;
            votedWeightWhite = 0;
            votedWeightBlack = 0;
            groupProposalDeadline = uint64(block.timestamp) + GROUP_VOTE_WINDOW;
        }
        emit TakebackProposed(msg.sender);
    }

    function acceptTakeback() external onlyActive {
        if (takebackProposer == address(0)) revert NoPendingTakebackProposal();
        address proposer = takebackProposer;
        address other = proposer == whitePlayer ? blackPlayer : whitePlayer;
        if (msg.sender != other) revert OnlyOpponentCanAcceptTakeback();
        if (!prevSnapshot.valid) revert NoSnapshotAvailable();

        bytes32 undoneHash = _currentHash();
        if (positionCounts[undoneHash] > 0) {
            positionCounts[undoneHash] -= 1;
        }

        address moverOfUndoneMove = prevSnapshot.whiteToMove ? whitePlayer : blackPlayer;
        uint256 refund = prevSnapshot.currentStake;

        board = prevSnapshot.board;
        castlingRights = prevSnapshot.castlingRights;
        enPassantSquare = prevSnapshot.enPassantSquare;
        whiteToMove = prevSnapshot.whiteToMove;
        halfmoveClock = prevSnapshot.halfmoveClock;
        plyCount = prevSnapshot.plyCount;
        currentStake = prevSnapshot.currentStake;
        pot -= refund;
        prevSnapshot.valid = false; // only one level of undo is supported
        takebackProposer = address(0);
        lastMoveTimestamp = uint64(block.timestamp);

        withdrawable[moverOfUndoneMove] += refund;
        emit TakebackAccepted(proposer, other, refund);
    }

    function rejectTakeback() external onlyActive {
        if (takebackProposer == address(0)) revert NoPendingTakebackProposal();
        address other = takebackProposer == whitePlayer ? blackPlayer : whitePlayer;
        if (msg.sender != other) revert OnlyOpponentCanRejectTakeback();
        takebackProposer = address(0);
        emit TakebackRejected(other);
    }

    /// @notice Escape hatch for a Duel takeback proposal nobody resolves.
    /// The proposer may cancel their own proposal immediately (they gain nothing by waiting --
    /// they could simply choose not to act instead); anyone else must wait until
    /// closedProposalDeadline passes, exactly like Crowd's cancelGroupProposal. Without this,
    /// an unresponsive `other` freezes the whole pot forever (see closedProposalDeadline's
    /// declaration and claimTimeoutVictory's guard).
    function cancelTakeback() external onlyActive {
        if (takebackProposer == address(0)) revert NoPendingTakebackProposal();
        address proposer = takebackProposer;
        bool byProposer = msg.sender == proposer;
        if (!byProposer && block.timestamp < closedProposalDeadline) revert ClosedProposalWindowStillOpen();
        takebackProposer = address(0);
        emit TakebackCancelled(proposer, byProposer);
    }

    // ---------- propose raising the minimum stake ----------
    // Duel: two-party consensus (propose/accept/reject below).
    // Crowd: weighted majority vote (`voteOnGroupProposal`/`cancelGroupProposal` below) --
    // NOT the same two-party consensus resign() uses in Duel, since a single minimal
    // contributor "voting" to end the game unilaterally would be exactly the griefing risk a
    // majority-vote design avoids; resign() has no Crowd equivalent at all for that reason.
    // Takeback follows the same Duel-two-party / Crowd-weighted-vote split as stake-increase
    // (see `proposeTakeback` below) -- both require only "does this side agree", which a
    // weighted vote answers fine; resign requires no agreement at all, which is the risk.

    function proposeStakeIncrease(uint256 newBaseStake) external onlyActive onlyPlayer duelSeatsFilled {
        if (mode != Mode.Duel && mode != Mode.Crowd) revert StakeIncreaseNotSupported();
        if (newBaseStake <= baseStake) revert MustBeStrictIncrease();
        if (takebackProposer != address(0)) revert PendingTakebackMustResolveFirst();

        if (mode == Mode.Duel) {
            if (stakeIncreaseProposer != address(0)) revert StakeIncreaseAlreadyProposed();
            stakeIncreaseProposer = msg.sender;
            proposedBaseStake = newBaseStake;
            closedProposalDeadline = uint64(block.timestamp) + GROUP_VOTE_WINDOW;
        } else {
            if (groupProposer != address(0)) revert GroupProposalAlreadyActive();
            groupProposer = msg.sender;
            groupProposalKind = ProposalKind.StakeIncrease;
            groupProposedValue = newBaseStake;
            groupProposalId += 1;
            yesWeightWhite = 0;
            yesWeightBlack = 0;
            votedWeightWhite = 0;
            votedWeightBlack = 0;
            groupProposalDeadline = uint64(block.timestamp) + GROUP_VOTE_WINDOW;
        }
        emit StakeIncreaseProposed(msg.sender, newBaseStake);
    }

    /// @dev Shared math for applying a stake increase (bump baseStake, then currentStake/cap if
    /// needed). Callers own clearing their respective proposer/value fields afterward -- Duel's
    /// stakeIncreaseProposer/proposedBaseStake, or Crowd's groupProposer/groupProposedValue.
    function _applyStakeIncrease(uint256 newBaseStake) private {
        baseStake = newBaseStake;
        if (currentStake < baseStake) {
            currentStake = baseStake;
        }
        uint256 cap = baseStake * MAX_STAKE_MULTIPLIER;
        if (currentStake > cap) {
            currentStake = cap;
        }
        emit StakeIncreaseAccepted(newBaseStake);
    }

    function acceptStakeIncrease() external onlyActive {
        if (mode != Mode.Duel) revert UseVoteStakeIncreaseInstead();
        if (stakeIncreaseProposer == address(0)) revert NoPendingStakeIncreaseProposal();
        address other = stakeIncreaseProposer == whitePlayer ? blackPlayer : whitePlayer;
        if (msg.sender != other) revert OnlyOpponentCanAcceptStakeIncrease();
        _applyStakeIncrease(proposedBaseStake);
        stakeIncreaseProposer = address(0);
        proposedBaseStake = 0;
    }

    function rejectStakeIncrease() external onlyActive {
        if (mode != Mode.Duel) revert UseCancelStakeIncreaseVoteInstead();
        if (stakeIncreaseProposer == address(0)) revert NoPendingStakeIncreaseProposal();
        address other = stakeIncreaseProposer == whitePlayer ? blackPlayer : whitePlayer;
        if (msg.sender != other) revert OnlyOpponentCanRejectStakeIncrease();
        emit StakeIncreaseRejected(proposedBaseStake);
        stakeIncreaseProposer = address(0);
        proposedBaseStake = 0;
    }

    /// @notice Escape hatch for a Duel stake-increase proposal nobody resolves --
    /// same reasoning as `cancelTakeback`. No funds are ever escrowed at propose time (only
    /// `proposedBaseStake`, a plain number), so there is nothing to refund on cancel.
    function cancelStakeIncrease() external onlyActive {
        if (stakeIncreaseProposer == address(0)) revert NoPendingStakeIncreaseProposal();
        address proposer = stakeIncreaseProposer;
        bool byProposer = msg.sender == proposer;
        if (!byProposer && block.timestamp < closedProposalDeadline) revert ClosedProposalWindowStillOpen();
        uint256 rejectedStake = proposedBaseStake;
        stakeIncreaseProposer = address(0);
        proposedBaseStake = 0;
        emit StakeIncreaseCancelled(proposer, rejectedStake, byProposer);
    }

    /// @notice Crowd's weighted vote covering BOTH stake-increase and takeback proposals
    /// (see `ProposalKind`/`groupProposalKind`) — passes the instant BOTH sides independently
    /// cross a strict majority of their own contributed weight (not combined) — a whale-heavy
    /// side cannot outvote the other side's shortfall. Weight = `contribution[msg.sender]`,
    /// frozen because `makeMove` (the only place contributions change) is blocked while any
    /// group proposal is pending. One vote per address per proposal (see `groupProposalId`); a
    /// vote is final and cannot be changed within the same proposal.
    ///
    /// A side is auto-cancelled the instant it becomes mathematically incapable of reaching
    /// >50%: even if every address on that side that HASN'T voted yet voted yes, the yes-weight
    /// still couldn't cross the threshold. This is a proof, not a heuristic -- contribution
    /// totals are frozen for as long as a proposal is pending (see above) and a cast vote can
    /// never change, so nothing later in this same round could flip the outcome. Without this, a
    /// side that has fully voted and fallen short (e.g. 75% turnout voting no) would deadlock the
    /// whole table -- no moves possible -- for the full 24h GROUP_VOTE_WINDOW even though the
    /// result was already final the moment the last vote came in. The pre-existing time-based
    /// cancelGroupProposal() stays as the fallback for the non-deadlocked case: some
    /// contribution-weight simply never votes either way.
    function voteOnGroupProposal(bool support) external onlyActive onlyPlayer {
        if (mode != Mode.Crowd) revert VotingOnlyForCrowd();
        if (groupProposer == address(0)) revert NoPendingGroupProposal();
        if (lastVotedGroupProposalId[msg.sender] == groupProposalId) revert AlreadyVotedOnThisProposal();
        lastVotedGroupProposalId[msg.sender] = groupProposalId;

        uint256 weight = contribution[msg.sender];
        bool voterIsWhite = colorOf[msg.sender] == Color.White;
        if (voterIsWhite) {
            votedWeightWhite += weight;
            if (support) yesWeightWhite += weight;
        } else {
            votedWeightBlack += weight;
            if (support) yesWeightBlack += weight;
        }
        emit GroupProposalVoteCast(msg.sender, support, weight);

        // A side with zero contribution so far (e.g. a takeback of the very first move, before
        // the other color has ever paid a stake) has nobody with standing to object -- treat it
        // as vacuously satisfied rather than permanently unsatisfiable, or a first-move takeback
        // could never pass until the 24h window lapses even though no one could possibly vote no.
        bool whiteOk = totalWhiteContribution == 0 || yesWeightWhite * 2 > totalWhiteContribution;
        bool blackOk = totalBlackContribution == 0 || yesWeightBlack * 2 > totalBlackContribution;
        if (whiteOk && blackOk) {
            _applyGroupProposal();
            return;
        }

        uint256 remainingWhite = totalWhiteContribution - votedWeightWhite;
        uint256 remainingBlack = totalBlackContribution - votedWeightBlack;
        bool whiteDead = totalWhiteContribution > 0 && (yesWeightWhite + remainingWhite) * 2 <= totalWhiteContribution;
        bool blackDead = totalBlackContribution > 0 && (yesWeightBlack + remainingBlack) * 2 <= totalBlackContribution;
        if (whiteDead || blackDead) {
            _cancelGroupProposal(true);
        }
    }

    /// @dev Dispatches to the stake-increase math or the takeback undo, then clears the shared
    /// group-proposal state common to both kinds.
    function _applyGroupProposal() private {
        if (groupProposalKind == ProposalKind.StakeIncrease) {
            _applyStakeIncrease(groupProposedValue);
        } else {
            _applyGroupTakeback();
        }
        groupProposer = address(0);
        groupProposalKind = ProposalKind.None;
        groupProposedValue = 0;
    }

    /// @dev Mirrors `acceptTakeback()`'s undo for Crowd, plus the contribution-ledger reversal
    /// Duel doesn't need (Duel never populates contribution/totalWhite.../totalBlack...).
    /// Without decrementing `contribution[lastMover]` and the relevant total, the refunded mover
    /// would keep counting toward a future `claimShare()` denominator for a move whose stake was
    /// already returned directly — double-counted funds. `colorOf` is deliberately left
    /// untouched: a color lock, once claimed (even by the very move being undone), stays
    /// permanent — undoing a move undoes the board state and the money, not who is "in" the game.
    function _applyGroupTakeback() private {
        bytes32 undoneHash = _currentHash();
        if (positionCounts[undoneHash] > 0) {
            positionCounts[undoneHash] -= 1;
        }

        uint256 refund = prevSnapshot.currentStake;
        bool undoneMoveWasWhite = prevSnapshot.whiteToMove;
        address refundTo = lastMover;

        board = prevSnapshot.board;
        castlingRights = prevSnapshot.castlingRights;
        enPassantSquare = prevSnapshot.enPassantSquare;
        whiteToMove = prevSnapshot.whiteToMove;
        halfmoveClock = prevSnapshot.halfmoveClock;
        plyCount = prevSnapshot.plyCount;
        currentStake = prevSnapshot.currentStake;
        pot -= refund;
        prevSnapshot.valid = false; // only one level of undo is supported
        lastMoveTimestamp = uint64(block.timestamp);

        contribution[refundTo] -= refund;
        if (undoneMoveWasWhite) {
            totalWhiteContribution -= refund;
        } else {
            totalBlackContribution -= refund;
        }

        withdrawable[refundTo] += refund;
        emit TakebackAccepted(groupProposer, refundTo, refund);
    }

    /// @dev Shared cleanup for both cancellation paths -- see `voteOnGroupProposal`'s deadlock
    /// detection and `cancelGroupProposal`'s time-based fallback below.
    function _cancelGroupProposal(bool deadlocked) private {
        emit GroupProposalCancelled(groupProposalKind, groupProposedValue, deadlocked);
        groupProposer = address(0);
        groupProposalKind = ProposalKind.None;
        groupProposedValue = 0;
    }

    /// @notice Permissionless: once the vote window closes without both sides reaching a
    /// majority, anyone can clear the stuck proposal so moves resume. Deliberately not
    /// restricted to a player — a vote that will never pass should not require one of the
    /// voters themselves to notice and act.
    ///
    /// The proposer may additionally cancel their own proposal immediately, but ONLY
    /// while votedWeightWhite == votedWeightBlack == 0 (nobody has voted either way yet). Unlike
    /// Duel's two-party proposals, a group proposal can carry OTHER contributors' votes, and
    /// votes are final/unchangeable by design (see `voteOnGroupProposal`) -- letting the proposer
    /// discard a proposal that already has cast votes would let them unilaterally void weight
    /// other addresses spent their one shot on. Before any vote lands, cancelling costs no one
    /// but the proposer, so no such restriction is needed.
    function cancelGroupProposal() external onlyActive {
        if (mode != Mode.Crowd) revert CancelVoteOnlyForCrowd();
        if (groupProposer == address(0)) revert NoPendingGroupProposal();
        bool byProposerBeforeAnyVote = msg.sender == groupProposer && votedWeightWhite == 0 && votedWeightBlack == 0;
        if (!byProposerBeforeAnyVote && block.timestamp < groupProposalDeadline) revert VoteWindowStillOpen();
        _cancelGroupProposal(false);
    }

    // ---------- checkmate / stalemate claims (verified atomically, no dispute window) ----------

    /// @notice Verifies AND finalizes in one atomic call: `hasLegalMove` proves the claim true
    /// or the call reverts outright, so a false claim costs only the caller's own gas and a
    /// real one pays out immediately -- no dispute window, no separate finalization step, no
    /// dependency on the table's `moveTimeout` (previously a correspondence-length table with a
    /// 48h moveTimeout could keep a winner's payout locked for up to 48h after a real mate).
    function claimCheckmate() external onlyActive onlyPlayer {
        if (!_isExpectedClaimant(msg.sender)) revert OnlyLastMoverMayClaim();
        if (!ChessEngine.isInCheck(board, !whiteToMove)) revert SideToMoveNotInCheck();
        ChessEngine.Position memory pos = ChessEngine.Position({
            board: board, castlingRights: castlingRights, enPassantSquare: enPassantSquare, whiteToMove: whiteToMove
        });
        if (ChessEngine.hasLegalMove(pos)) revert NotActuallyCheckmate();
        Color claimantColor =
            mode == Mode.Duel ? (msg.sender == whitePlayer ? Color.White : Color.Black) : colorOf[msg.sender];
        _finalize(claimantColor == Color.White ? Result.WhiteWon : Result.BlackWon);
    }

    /// @notice See `claimCheckmate` -- same atomic verify-then-finalize pattern, for the draw case.
    function claimStalemate() external onlyActive onlyPlayer {
        if (!_isExpectedClaimant(msg.sender)) revert OnlyLastMoverMayClaim();
        if (ChessEngine.isInCheck(board, !whiteToMove)) revert SideToMoveInCheckUseCheckmate();
        ChessEngine.Position memory pos = ChessEngine.Position({
            board: board, castlingRights: castlingRights, enPassantSquare: enPassantSquare, whiteToMove: whiteToMove
        });
        if (ChessEngine.hasLegalMove(pos)) revert NotActuallyStalemate();
        _finalize(Result.Draw);
    }

    /// @dev The claimant must be locked to the color that just moved (i.e. NOT the color
    /// whose turn it currently is): whiteToMove==true means black just moved and is the one
    /// entitled to claim white has no escape, and vice versa.
    function _isExpectedClaimant(address who) private view returns (bool) {
        Color expected = whiteToMove ? Color.Black : Color.White;
        if (mode == Mode.Duel) {
            address expectedAddr = expected == Color.White ? whitePlayer : blackPlayer;
            return who == expectedAddr;
        }
        return colorOf[who] == expected;
    }

    // ---------- direct (non-disputable) draw claims by players ----------

    function claimFiftyMoveRule() external onlyActive onlyPlayer {
        if (halfmoveClock < FIFTY_MOVE_HALFMOVES) revert FiftyMoveRuleNotReached();
        _finalize(Result.Draw);
    }

    function claimThreefoldRepetition() external onlyActive onlyPlayer {
        if (positionCounts[_currentHash()] < THREEFOLD_COUNT) revert RepetitionThresholdNotReached();
        _finalize(Result.Draw);
    }

    // ---------- claim eligibility (read-only convenience for frontends) ----------

    struct ClaimableActions {
        bool checkmate;
        bool stalemate;
        bool fiftyMoveRule;
        bool threefoldRepetition;
        bool timeoutVictory;
    }

    /// @notice Bundles every "is X claimable right now" check into one call, so a frontend can
    /// show a proactive "you can claim mate / a draw / the timeout" banner instead of making the
    /// player guess and either miss a real opportunity or eat a revert from a false one. Pure
    /// read -- changes nothing on-chain, and deliberately not gated by `onlyPlayer` or
    /// `_isExpectedClaimant`: those still guard the actual claim functions below, but this only
    /// reports facts about the current position, not who is allowed to act on them -- a
    /// frontend already knows the viewer's own color and can gate button visibility itself.
    function claimableActions() external view returns (ClaimableActions memory a) {
        if (status != Status.Active) return a; // every field defaults to false

        bool inCheck = ChessEngine.isInCheck(board, !whiteToMove);
        ChessEngine.Position memory pos = ChessEngine.Position({
            board: board, castlingRights: castlingRights, enPassantSquare: enPassantSquare, whiteToMove: whiteToMove
        });
        bool noLegalMove = !ChessEngine.hasLegalMove(pos);
        a.checkmate = inCheck && noLegalMove;
        a.stalemate = !inCheck && noLegalMove;

        bytes32 h = _currentHash();
        a.fiftyMoveRule = halfmoveClock >= FIFTY_MOVE_HALFMOVES;
        a.threefoldRepetition = positionCounts[h] >= THREEFOLD_COUNT;

        // Mirrors claimTimeoutVictory's exact guard chain (including the Crowd group-vote
        // exemption -- see that function's NatSpec) so this never reports a timeout claim as
        // available when the real call would actually revert.
        bool noBlockingVote = takebackProposer == address(0) && (mode != Mode.Duel || stakeIncreaseProposer == address(0));
        a.timeoutVictory = moveTimeout != 0 && noBlockingVote && block.timestamp >= lastMoveTimestamp + moveTimeout;
    }

    /// @dev Duel tables only — never available for Crowd, no matter how many contributors have
    /// joined: resign needs no one else's agreement, so a single (possibly minimal) contributor
    /// could unilaterally destroy every other contributor's stake on their own side — the exact
    /// griefing risk a majority vote can't fix, since there's nothing to vote on. Crowd games can
    /// only end early via takeback-to-a-drawn-out-loss, a real chess outcome (mate/stalemate/
    /// draw), or permissionless timeout. A Duel public challenge (one side started as address(0))
    /// DOES get resign() — see `duelSeatsFilled` — once its vacancy is claimed it's a normal
    /// two-real-address Duel game like any other.
    function resign() external onlyActive onlyPlayer duelSeatsFilled {
        if (mode != Mode.Duel) revert ResignOnlyForDuel();
        Color myColor = msg.sender == whitePlayer ? Color.White : Color.Black;
        _finalize(myColor == Color.White ? Result.BlackWon : Result.WhiteWon);
    }

    // ---------- permissionless finalization claim: anyone can settle an abandoned table once
    // its move timeout has elapsed, so an unresponsive opponent can never freeze the pot
    // forever. No caller reward -- calling this costs the caller only their own gas. ----------

    function claimTimeoutVictory() external onlyActive {
        if (takebackProposer != address(0)) revert PendingTakebackMustResolveFirst();
        // Duel only: a pending stake-increase there is two-party consensus, so the sole other
        // player can self-correct with reject+claim in one breath — not a DoS surface. Crowd
        // group votes (stake-increase OR takeback, `groupProposer`) are deliberately EXEMPT from
        // this guard: those tables can have moveTimeout == 0 (no idle-move timer needed because
        // anyone can step in) or, even with a timer, a stuck 24h vote (GROUP_VOTE_WINDOW) must
        // never be usable to suppress the one mechanism that unsticks an abandoned table -- the
        // same reasoning applies identically to both the stake-increase and takeback group votes.
        if (mode == Mode.Duel) {
            if (stakeIncreaseProposer != address(0)) revert PendingStakeIncreaseMustResolveFirst();
        }
        if (moveTimeout == 0) revert NoMoveTimeoutConfigured();
        if (block.timestamp < lastMoveTimestamp + moveTimeout) revert MoveTimeoutNotReached();
        _finalize(whiteToMove ? Result.BlackWon : Result.WhiteWon);
    }

    // ---------- finalization: fees, then Duel direct-credit or Crowd share bookkeeping ----------

    function _finalize(Result _result) private {
        status = Status.Finished;
        result = _result;

        uint256 amount = pot;
        pot = 0;

        if (protocolFeeBps > 0 && protocolFeeRecipient != address(0)) {
            uint256 fee = (amount * protocolFeeBps) / 10000;
            amount -= fee;
            withdrawable[protocolFeeRecipient] += fee;
        }
        if (referralFeeBps > 0 && frontendRecipient != address(0)) {
            uint256 fee = (amount * referralFeeBps) / 10000;
            amount -= fee;
            withdrawable[frontendRecipient] += fee;
        }

        uint256 wShare;
        uint256 bShare;
        if (_result == Result.WhiteWon) {
            wShare = amount;
        } else if (_result == Result.BlackWon) {
            bShare = amount;
        } else {
            wShare = amount / 2;
            bShare = amount - wShare;
        }

        if (mode == Mode.Duel) {
            withdrawable[whitePlayer] += wShare;
            withdrawable[blackPlayer] += bShare;
        } else {
            whitePotShare = wShare;
            blackPotShare = bShare;
            sharesFinalized = true;
        }

        emit GameFinished(_result, msg.sender);
    }

    /// @notice Crowd-mode contributors pull their proportional share of their side's pot
    /// allocation once the game is finished. Pull-based specifically to avoid an O(N) payout
    /// loop over an unbounded contributor list at finalization time (gas-limit / DoS risk).
    /// @dev Integer division leaves at most a few wei of "dust" per side in the contract,
    /// which is an accepted tradeoff, not a bug.
    function claimShare() external {
        if (mode != Mode.Crowd) revert DuelSettlesViaWithdraw();
        if (!sharesFinalized) revert GameNotFinishedYet();
        Color c = colorOf[msg.sender];
        if (c == Color.None) revert NotAContributor();
        if (hasClaimedShare[msg.sender]) revert AlreadyClaimedShare();
        hasClaimedShare[msg.sender] = true;

        uint256 sideShare = c == Color.White ? whitePotShare : blackPotShare;
        uint256 totalSideContribution = c == Color.White ? totalWhiteContribution : totalBlackContribution;
        if (totalSideContribution == 0 || sideShare == 0) {
            return;
        }
        uint256 share = (sideShare * contribution[msg.sender]) / totalSideContribution;
        withdrawable[msg.sender] += share;
        emit ShareClaimed(msg.sender, share);
    }

    // ---------- withdrawals (pull-payment pattern) ----------
    //
    // Sending funds directly with `.call` inside game-finalization functions would mean a
    // winner/fee-recipient address that reverts on receive (deliberately or not)
    // reverts the ENTIRE finalize/timeout/resign transaction, permanently stuck-locking the
    // pot for every other, honest party too. Payouts are credited to a withdrawable balance
    // instead; anyone pulls their own funds with withdraw(), so one broken recipient can
    // never block game resolution or someone else's funds.

    mapping(address => uint256) public withdrawable;

    function withdraw() external {
        uint256 amount = withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        withdrawable[msg.sender] = 0; // effect before interaction, native or token alike
        if (token == address(0)) {
            (bool ok,) = msg.sender.call{value: amount}("");
            if (!ok) revert WithdrawTransferFailed();
        } else {
            if (!IERC20(token).transfer(msg.sender, amount)) revert WithdrawTransferFailed();
        }
    }
}
