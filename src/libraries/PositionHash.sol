// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Hashes a full chess position (board + castling rights + en passant + side to move)
/// for O(1) threefold/fivefold repetition counting. All four components are required —
/// the repetition rule only counts positions where rights and side-to-move also match.
library PositionHash {
    function hash(uint256 board_, uint8 castlingRights, uint8 enPassantSquare, bool whiteToMove)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(board_, castlingRights, enPassantSquare, whiteToMove));
    }
}
