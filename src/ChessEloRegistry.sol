// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ChessGameTable} from "./ChessGameTable.sol";
import {ChessGameFactory} from "./ChessGameFactory.sol";

/// @notice Permissionless ELO rating registry for Duel-mode games. Fully independent
/// of ChessGameTable/ChessGameFactory -- neither of those contracts knows this exists, and
/// this contract never writes to them. Anyone can call `recordResult` once a Duel table
/// finishes; both players' ratings update via the standard ELO formula.
///
/// @dev Scope is deliberately Duel-only: Crowd/Squad let many different wallets move for the
/// same color across a single game, so "whose rating changes" has no single well-defined
/// answer there without a much more involved per-move-attribution design. Duel always has
/// exactly one wallet per color for its entire life (see ChessGameTable's `whitePlayer`/
/// `blackPlayer`), so the mapping from a finished game to "these two ratings changed" is
/// unambiguous.
///
/// @dev Known, deliberately-unmitigated limitation: nothing here (or in ChessGameTable) stops
/// one person from controlling both `whitePlayer` and `blackPlayer` of a Duel table and
/// steering the result however they like -- every Duel table already requires a nonzero
/// `baseStake` and `whitePlayer != blackPlayer` as distinct addresses (ChessGameTable's own
/// `BaseStakeMustBePositive`/`PlayersMustDiffer` checks), so self-play costs real gas and fees
/// on every game, but does not cost anywhere near the full stake (most of it just moves
/// between the farmer's own two wallets). This is the same Sybil-resistance limitation every
/// permissionless on-chain reputation system without an identity layer has; solving it
/// properly (staking-weighted rating, social attestation, etc.) is a separate, larger design
/// question deliberately left out of scope here.
contract ChessEloRegistry {
    ChessGameFactory public immutable factory;

    uint16 public constant DEFAULT_RATING = 1200;
    uint16 public constant K_FACTOR = 32;

    mapping(address => uint16) public rating;
    mapping(address => bool) public hasPlayed;
    /// @notice Keyed by TABLE address, not by player -- guarantees a finished game can only
    /// ever move ratings once, no matter how many times someone calls recordResult on it.
    mapping(address => bool) public recorded;

    event RatingUpdated(address indexed player, address indexed table, int32 delta, uint16 newRating);

    error UnknownTable();
    error AlreadyRecorded();
    error NotDuelMode();
    error GameNotFinished();

    constructor(ChessGameFactory _factory) {
        factory = _factory;
    }

    /// @notice Permissionless: anyone can settle a finished Duel table's rating impact, same
    /// keeper-style pattern as ChessGameTable's claimTimeoutVictory. No reward for calling it --
    /// ratings aren't money, and the frontend can simply call this itself right after a game
    /// it's displaying finishes.
    function recordResult(address table) external {
        if (!factory.isTable(table)) revert UnknownTable();
        if (recorded[table]) revert AlreadyRecorded();
        ChessGameTable t = ChessGameTable(table);
        if (t.mode() != ChessGameTable.Mode.Duel) revert NotDuelMode();
        if (t.status() != ChessGameTable.Status.Finished) revert GameNotFinished();
        recorded[table] = true;

        address white = t.whitePlayer();
        address black = t.blackPlayer();
        ChessGameTable.Result result = t.result();

        uint16 rWhite = _currentRating(white);
        uint16 rBlack = _currentRating(black);

        // Actual score out of 1000 (1000/500/0) instead of a fractional 1/0.5/0 -- Solidity has
        // no native fixed-point type, and thousandths give the expected-score lookup below
        // plenty of headroom without needing a larger scale.
        uint256 actualWhite;
        if (result == ChessGameTable.Result.WhiteWon) {
            actualWhite = 1000;
        } else if (result == ChessGameTable.Result.BlackWon) {
            actualWhite = 0;
        } else {
            actualWhite = 500;
        }

        uint256 expectedWhite = _expectedScore(rWhite, rBlack);

        // casting to 'int256' is safe because actualWhite/expectedWhite are both bounded to
        // [0, 1000] by construction (thousandths scale), nowhere near int256's range
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 deltaWhite = (int256(uint256(K_FACTOR)) * (int256(actualWhite) - int256(expectedWhite))) / 1000;
        int256 deltaBlack = -deltaWhite; // zero-sum by construction

        uint16 newWhite = _applyDelta(rWhite, deltaWhite);
        uint16 newBlack = _applyDelta(rBlack, deltaBlack);

        rating[white] = newWhite;
        rating[black] = newBlack;
        hasPlayed[white] = true;
        hasPlayed[black] = true;

        // casting to 'int32' is safe because deltaWhite/deltaBlack are bounded to
        // [-K_FACTOR, K_FACTOR] = [-32, 32] by the /1000 division above, far inside int32
        // forge-lint: disable-next-line(unsafe-typecast)
        emit RatingUpdated(white, table, int32(deltaWhite), newWhite);
        // forge-lint: disable-next-line(unsafe-typecast)
        emit RatingUpdated(black, table, int32(deltaBlack), newBlack);
    }

    /// @notice Convenience view for external callers (frontend, other contracts): returns the
    /// EFFECTIVE rating, i.e. DEFAULT_RATING for anyone who hasn't played a recorded game yet,
    /// instead of the raw zero the `rating` mapping getter returns for unplayed addresses.
    function effectiveRating(address player) external view returns (uint16) {
        return _currentRating(player);
    }

    function _currentRating(address player) private view returns (uint16) {
        return hasPlayed[player] ? rating[player] : DEFAULT_RATING;
    }

    /// @dev Standard ELO expected-score curve `1000 / (1 + 10^(diff/400))`, diff = ratingB -
    /// ratingA, clamped to [-800, 800] (beyond that the real curve is already within ~1% of
    /// its 0/1000 asymptote, so clamping costs no meaningful accuracy). No floating point in
    /// Solidity, so this is a 33-point lookup table (every 50 rating points) with linear
    /// interpolation between the two nearest points -- precomputed offline, not derived
    /// on-chain. `memory` array literal, not `constant`/`immutable` (Solidity doesn't support
    /// constant array types), so it costs a handful of PUSH+MSTORE per call, no storage reads.
    function _expectedScore(uint16 ratingA, uint16 ratingB) private pure returns (uint256) {
        int256 diff = int256(uint256(ratingB)) - int256(uint256(ratingA));
        if (diff < -800) diff = -800;
        if (diff > 800) diff = 800;

        uint16[33] memory table = [
            uint16(990),
            987,
            983,
            977,
            969,
            960,
            947,
            930,
            909,
            882,
            849,
            808,
            760,
            703,
            640,
            571,
            500,
            429,
            360,
            297,
            240,
            192,
            151,
            118,
            91,
            70,
            53,
            40,
            31,
            23,
            17,
            13,
            10
        ];

        // casting to 'uint256' is safe because diff is clamped to [-800, 800] above, so
        // diff + 800 is always in [0, 1600]
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 shifted = uint256(diff + 800); // 0..1600
        uint256 idx = shifted / 50; // 0..32
        uint256 rem = shifted % 50; // 0..49
        if (idx == 32 || rem == 0) return table[idx];

        uint256 lo = table[idx];
        uint256 hi = table[idx + 1];
        if (hi >= lo) {
            return lo + ((hi - lo) * rem) / 50;
        }
        return lo - ((lo - hi) * rem) / 50;
    }

    function _applyDelta(uint16 current, int256 delta) private pure returns (uint16) {
        int256 next = int256(uint256(current)) + delta;
        if (next < 0) return 0;
        if (next > int256(uint256(type(uint16).max))) return type(uint16).max;
        // casting to 'uint16'/'uint256' is safe because the two checks above already clamp
        // `next` to exactly [0, type(uint16).max]
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(uint256(next));
    }
}
