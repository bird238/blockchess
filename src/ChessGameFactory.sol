// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ChessGameTable} from "./ChessGameTable.sol";

/// @notice Deploys cheap EIP-1167 minimal-proxy clones of a single ChessGameTable
/// implementation. Anyone can create a table through their own frontend and be recorded as
/// its referral recipient, choosing their own referral rate up to
/// ChessGameTable.MAX_REFERRAL_FEE_BPS; the deployer/owner collects a protocol fee on every
/// table, fixed per-table at creation time so a later fee change never affects existing games.
contract ChessGameFactory is Ownable {
    uint16 public constant MAX_PROTOCOL_FEE_BPS = 500; // 5% hard ceiling, enforced in the setter
    // Mirrors ChessGameTable.MAX_REFERRAL_FEE_BPS -- kept as its own constant here (rather than
    // referenced cross-contract, which Solidity doesn't allow for a plain, non-library contract)
    // since this is the value actually enforced before ever calling initialize().
    uint16 public constant MAX_REFERRAL_FEE_BPS = 500; // 5% hard ceiling, enforced here

    address public immutable implementation;

    address public protocolFeeRecipient;
    uint16 public protocolFeeBps;

    /// @notice Lets any external contract (e.g. ChessEloRegistry) verify an address is a genuine
    /// clone this factory deployed, without needing this factory to know those contracts exist.
    /// Set true at the end of each create*Table function, never unset.
    mapping(address => bool) public isTable;

    /// @notice Owner-curated ERC20 allowlist for table stakes. address(0) (native currency) is
    /// always implicitly allowed and never stored here. Only allowlist tokens with a standard,
    /// non-fee-on-transfer, non-rebasing transfer/transferFrom that returns a real bool --
    /// ChessGameTable performs no balance-delta verification and trusts the transferred amount
    /// equals the requested amount, to stay within its EIP-170 bytecode budget. A token with
    /// transfer hooks (ERC777-style) is safe against reentrancy on the table side (it applies
    /// its own state before ever calling out, see ChessGameTable.makeMove/withdraw), but still
    /// must not be fee-on-transfer/rebasing or it will desync the table's pot accounting.
    /// Concretely: do NOT allowlist mainnet-style USDT or any token whose transfer/transferFrom
    /// returns no data instead of a bool -- ChessGameTable's ABI-typed call will revert on every
    /// use of such a token, making any table created with it permanently unusable.
    mapping(address => bool) public allowedTokens;

    event TableCreated(
        address indexed table, ChessGameTable.Mode mode, address indexed creator, address frontendRecipient
    );
    event ProtocolFeeUpdated(address recipient, uint16 bps);
    event TokenAllowlistUpdated(address indexed token, bool allowed);

    constructor(address initialOwner, address _protocolFeeRecipient, uint16 _protocolFeeBps) Ownable(initialOwner) {
        require(_protocolFeeBps <= MAX_PROTOCOL_FEE_BPS, "fee exceeds max");
        implementation = address(new ChessGameTable());
        protocolFeeRecipient = _protocolFeeRecipient;
        protocolFeeBps = _protocolFeeBps;
    }

    /// @notice Only affects tables created AFTER this call — each table copies the current
    /// rate into its own storage at creation and never re-reads the factory afterward.
    function setProtocolFee(address recipient, uint16 bps) external onlyOwner {
        require(bps <= MAX_PROTOCOL_FEE_BPS, "fee exceeds max");
        protocolFeeRecipient = recipient;
        protocolFeeBps = bps;
        emit ProtocolFeeUpdated(recipient, bps);
    }

    /// @notice Only affects tables created AFTER this call -- each table copies `token` into its
    /// own storage at creation and never re-reads the factory afterward. Removing a token from
    /// the allowlist never affects existing tables already using it. Requires actual contract
    /// code at `token` when enabling (not when disabling) purely as a typo guard for the owner --
    /// this is not a security boundary, since `token` is always owner-supplied.
    function setTokenAllowed(address token, bool allowed) external onlyOwner {
        require(!allowed || token.code.length > 0, "token must be a contract");
        allowedTokens[token] = allowed;
        emit TokenAllowlistUpdated(token, allowed);
    }

    function createDuelTable(
        address white,
        address black,
        uint256 baseStake,
        uint32 rampPly,
        uint32 moveTimeout,
        ChessGameTable.StakeCurve curve,
        address frontendRecipient,
        uint16 referralFeeBps,
        address token
    ) external returns (address table) {
        require(referralFeeBps <= MAX_REFERRAL_FEE_BPS, "referral fee exceeds max");
        require(token == address(0) || allowedTokens[token], "token not allowed");
        table = Clones.clone(implementation);
        ChessGameTable(table)
            .initialize(
                ChessGameTable.Mode.Duel,
                white,
                black,
                baseStake,
                rampPly,
                moveTimeout,
                curve,
                protocolFeeRecipient,
                protocolFeeBps,
                frontendRecipient,
                referralFeeBps,
                token
            );
        isTable[table] = true;
        emit TableCreated(table, ChessGameTable.Mode.Duel, msg.sender, frontendRecipient);
    }

    function createCrowdTable(
        uint256 baseStake,
        uint32 rampPly,
        uint32 moveTimeout,
        ChessGameTable.StakeCurve curve,
        address frontendRecipient,
        uint16 referralFeeBps,
        address token
    ) external returns (address table) {
        require(referralFeeBps <= MAX_REFERRAL_FEE_BPS, "referral fee exceeds max");
        require(token == address(0) || allowedTokens[token], "token not allowed");
        table = Clones.clone(implementation);
        ChessGameTable(table)
            .initialize(
                ChessGameTable.Mode.Crowd,
                address(0),
                address(0),
                baseStake,
                rampPly,
                moveTimeout,
                curve,
                protocolFeeRecipient,
                protocolFeeBps,
                frontendRecipient,
                referralFeeBps,
                token
            );
        isTable[table] = true;
        emit TableCreated(table, ChessGameTable.Mode.Crowd, msg.sender, frontendRecipient);
    }
}
