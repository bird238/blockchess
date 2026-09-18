// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Pure on-chain chess move-legality engine.
/// @dev Board is packed into a single uint256: 4 bits per square (64 squares),
/// square index = rank*8+file, a1=0 ... h8=63.
/// Nibble encoding: 0 = empty. Bits 0-2 = piece type, bit 3 = color (0=white,1=black).
library ChessEngine {
    uint8 internal constant EMPTY = 0;
    uint8 internal constant PAWN = 1;
    uint8 internal constant KNIGHT = 2;
    uint8 internal constant BISHOP = 3;
    uint8 internal constant ROOK = 4;
    uint8 internal constant QUEEN = 5;
    uint8 internal constant KING = 6;
    uint8 internal constant BLACK_FLAG = 0x08;

    uint8 internal constant NO_EN_PASSANT = 255;

    // castlingRights bits
    uint8 internal constant WK = 0x01;
    uint8 internal constant WQ = 0x02;
    uint8 internal constant BK = 0x04;
    uint8 internal constant BQ = 0x08;

    struct Position {
        uint256 board;
        uint8 castlingRights;
        uint8 enPassantSquare;
        bool whiteToMove;
    }

    struct MoveResult {
        uint256 board;
        uint8 castlingRights;
        uint8 enPassantSquare;
        bool isCapture;
        bool isPawnMove;
    }

    // ---------- board bit-packing helpers ----------

    function getPiece(uint256 board_, uint8 sq) internal pure returns (uint8) {
        return uint8((board_ >> (uint256(sq) * 4)) & 0xF);
    }

    function setPiece(uint256 board_, uint8 sq, uint8 piece) internal pure returns (uint256) {
        uint256 mask = ~(uint256(0xF) << (uint256(sq) * 4));
        return (board_ & mask) | (uint256(piece) << (uint256(sq) * 4));
    }

    function pieceType(uint8 piece) internal pure returns (uint8) {
        return piece & 0x07;
    }

    function isBlackPiece(uint8 piece) internal pure returns (bool) {
        return (piece & BLACK_FLAG) != 0;
    }

    function fileOf(uint8 sq) internal pure returns (uint8) {
        return sq % 8;
    }

    function rankOf(uint8 sq) internal pure returns (uint8) {
        return sq / 8;
    }

    // ---------- attack detection ----------

    function findKing(uint256 board_, bool black) internal pure returns (uint8) {
        for (uint16 sq = 0; sq < 64; sq++) {
            uint8 p = getPiece(board_, uint8(sq));
            if (p != EMPTY && pieceType(p) == KING && isBlackPiece(p) == black) {
                return uint8(sq);
            }
        }
        revert("ChessEngine: king not found");
    }

    function isInCheck(uint256 board_, bool black) internal pure returns (bool) {
        uint8 kingSq = findKing(board_, black);
        return isSquareAttacked(board_, kingSq, !black);
    }

    function isSquareAttacked(uint256 board_, uint8 sq, bool byBlack) internal pure returns (bool) {
        uint8 f = fileOf(sq);
        uint8 r = rankOf(sq);

        // knights
        int8[8] memory kf = [int8(1), int8(2), int8(2), int8(1), int8(-1), int8(-2), int8(-2), int8(-1)];
        int8[8] memory kr = [int8(2), int8(1), int8(-1), int8(-2), int8(-2), int8(-1), int8(1), int8(2)];
        for (uint8 i = 0; i < 8; i++) {
            int16 nf = int16(int8(f)) + int16(kf[i]);
            int16 nr = int16(int8(r)) + int16(kr[i]);
            if (nf >= 0 && nf < 8 && nr >= 0 && nr < 8) {
                uint8 p = getPiece(board_, uint8(uint16(nr)) * 8 + uint8(uint16(nf)));
                if (p != EMPTY && pieceType(p) == KNIGHT && isBlackPiece(p) == byBlack) return true;
            }
        }

        // king
        for (int8 df = -1; df <= 1; df++) {
            for (int8 dr = -1; dr <= 1; dr++) {
                if (df == 0 && dr == 0) continue;
                int16 nf = int16(int8(f)) + df;
                int16 nr = int16(int8(r)) + dr;
                if (nf >= 0 && nf < 8 && nr >= 0 && nr < 8) {
                    uint8 p = getPiece(board_, uint8(uint16(nr)) * 8 + uint8(uint16(nf)));
                    if (p != EMPTY && pieceType(p) == KING && isBlackPiece(p) == byBlack) return true;
                }
            }
        }

        // pawns
        if (byBlack) {
            if (r + 1 < 8) {
                if (f >= 1) {
                    uint8 p = getPiece(board_, (r + 1) * 8 + (f - 1));
                    if (p != EMPTY && pieceType(p) == PAWN && isBlackPiece(p)) return true;
                }
                if (f + 1 < 8) {
                    uint8 p = getPiece(board_, (r + 1) * 8 + (f + 1));
                    if (p != EMPTY && pieceType(p) == PAWN && isBlackPiece(p)) return true;
                }
            }
        } else {
            if (r >= 1) {
                if (f >= 1) {
                    uint8 p = getPiece(board_, (r - 1) * 8 + (f - 1));
                    if (p != EMPTY && pieceType(p) == PAWN && !isBlackPiece(p)) return true;
                }
                if (f + 1 < 8) {
                    uint8 p = getPiece(board_, (r - 1) * 8 + (f + 1));
                    if (p != EMPTY && pieceType(p) == PAWN && !isBlackPiece(p)) return true;
                }
            }
        }

        // rook/queen sliders
        int8[4] memory rdf = [int8(1), int8(-1), int8(0), int8(0)];
        int8[4] memory rdr = [int8(0), int8(0), int8(1), int8(-1)];
        for (uint8 i = 0; i < 4; i++) {
            int16 cf = int16(int8(f));
            int16 cr = int16(int8(r));
            while (true) {
                cf += rdf[i];
                cr += rdr[i];
                if (cf < 0 || cf >= 8 || cr < 0 || cr >= 8) break;
                uint8 p = getPiece(board_, uint8(uint16(cr)) * 8 + uint8(uint16(cf)));
                if (p != EMPTY) {
                    if (isBlackPiece(p) == byBlack && (pieceType(p) == ROOK || pieceType(p) == QUEEN)) return true;
                    break;
                }
            }
        }

        // bishop/queen diagonals
        int8[4] memory bdf = [int8(1), int8(1), int8(-1), int8(-1)];
        int8[4] memory bdr = [int8(1), int8(-1), int8(1), int8(-1)];
        for (uint8 i = 0; i < 4; i++) {
            int16 cf = int16(int8(f));
            int16 cr = int16(int8(r));
            while (true) {
                cf += bdf[i];
                cr += bdr[i];
                if (cf < 0 || cf >= 8 || cr < 0 || cr >= 8) break;
                uint8 p = getPiece(board_, uint8(uint16(cr)) * 8 + uint8(uint16(cf)));
                if (p != EMPTY) {
                    if (isBlackPiece(p) == byBlack && (pieceType(p) == BISHOP || pieceType(p) == QUEEN)) return true;
                    break;
                }
            }
        }

        return false;
    }

    // ---------- piece movement patterns ----------

    function _abs8(int16 v) private pure returns (int16) {
        return v < 0 ? -v : v;
    }

    function _isKnightPattern(uint8 from, uint8 to) private pure returns (bool) {
        int16 fd = _abs8(int16(uint16(fileOf(to))) - int16(uint16(fileOf(from))));
        int16 rd = _abs8(int16(uint16(rankOf(to))) - int16(uint16(rankOf(from))));
        return (fd == 1 && rd == 2) || (fd == 2 && rd == 1);
    }

    function _isKingPattern(uint8 from, uint8 to) private pure returns (bool) {
        int16 fd = _abs8(int16(uint16(fileOf(to))) - int16(uint16(fileOf(from))));
        int16 rd = _abs8(int16(uint16(rankOf(to))) - int16(uint16(rankOf(from))));
        return fd <= 1 && rd <= 1;
    }

    function _isRookPattern(uint256 board_, uint8 from, uint8 to) private pure returns (bool) {
        uint8 ff = fileOf(from);
        uint8 fr = rankOf(from);
        uint8 tf = fileOf(to);
        uint8 tr = rankOf(to);
        if (ff != tf && fr != tr) return false;
        int8 df = ff == tf ? int8(0) : (tf > ff ? int8(1) : int8(-1));
        int8 dr = fr == tr ? int8(0) : (tr > fr ? int8(1) : int8(-1));
        int8 cf = int8(ff);
        int8 cr = int8(fr);
        while (true) {
            cf += df;
            cr += dr;
            uint8 sq = uint8(cr) * 8 + uint8(cf);
            if (sq == to) break;
            if (getPiece(board_, sq) != EMPTY) return false;
        }
        return true;
    }

    function _isBishopPattern(uint256 board_, uint8 from, uint8 to) private pure returns (bool) {
        uint8 ff = fileOf(from);
        uint8 fr = rankOf(from);
        uint8 tf = fileOf(to);
        uint8 tr = rankOf(to);
        int16 fdiff = int16(uint16(tf)) - int16(uint16(ff));
        int16 rdiff = int16(uint16(tr)) - int16(uint16(fr));
        if (fdiff == 0 || rdiff == 0) return false;
        if (_abs8(fdiff) != _abs8(rdiff)) return false;
        int8 df = fdiff > 0 ? int8(1) : int8(-1);
        int8 dr = rdiff > 0 ? int8(1) : int8(-1);
        int8 cf = int8(ff);
        int8 cr = int8(fr);
        while (true) {
            cf += df;
            cr += dr;
            uint8 sq = uint8(cr) * 8 + uint8(cf);
            if (sq == to) break;
            if (getPiece(board_, sq) != EMPTY) return false;
        }
        return true;
    }

    function _isPawnPatternLegal(Position memory pos, uint8 from, uint8 to, uint8 target, bool black)
        private
        pure
        returns (bool legal, bool isEnPassant)
    {
        uint8 ff = fileOf(from);
        uint8 fr = rankOf(from);
        uint8 tf = fileOf(to);
        uint8 tr = rankOf(to);
        int16 fdiff = int16(uint16(tf)) - int16(uint16(ff));
        int16 rdiff = int16(uint16(tr)) - int16(uint16(fr));
        int16 dir = black ? int16(-1) : int16(1);

        if (fdiff == 0 && rdiff == dir && target == EMPTY) {
            return (true, false);
        }

        uint8 startRank = black ? 6 : 1;
        if (fdiff == 0 && rdiff == 2 * dir && fr == startRank && target == EMPTY) {
            uint8 mid = uint8(uint16(int16(uint16(from)) + dir * 8));
            if (getPiece(pos.board, mid) == EMPTY) return (true, false);
            return (false, false);
        }

        if ((fdiff == 1 || fdiff == -1) && rdiff == dir) {
            if (target != EMPTY) {
                return (true, false);
            }
            if (pos.enPassantSquare == to) {
                return (true, true);
            }
        }

        return (false, false);
    }

    // ---------- castling ----------

    function _tryCastle(Position memory pos, bool kingside) private pure returns (bool ok, MoveResult memory mr) {
        bool white = pos.whiteToMove;
        uint8 kingFrom = white ? 4 : 60;
        uint8 kingTo = kingside ? (white ? 6 : 62) : (white ? 2 : 58);
        uint8 rookFrom = kingside ? (white ? 7 : 63) : (white ? 0 : 56);
        uint8 rookTo = kingside ? (white ? 5 : 61) : (white ? 3 : 59);
        uint8 rightBit = white ? (kingside ? WK : WQ) : (kingside ? BK : BQ);

        if ((pos.castlingRights & rightBit) == 0) return (false, mr);

        uint8 rook = getPiece(pos.board, rookFrom);
        bool moverIsBlackForCastle = !white;
        if (pieceType(rook) != ROOK || isBlackPiece(rook) != moverIsBlackForCastle) return (false, mr);

        if (kingside) {
            if (getPiece(pos.board, kingFrom + 1) != EMPTY || getPiece(pos.board, kingFrom + 2) != EMPTY) {
                return (false, mr);
            }
        } else {
            if (
                getPiece(pos.board, kingFrom - 1) != EMPTY || getPiece(pos.board, kingFrom - 2) != EMPTY
                    || getPiece(pos.board, kingFrom - 3) != EMPTY
            ) {
                return (false, mr);
            }
        }

        // byBlack must be the OPPONENT's color: white castling (white=true) must check
        // attacks BY BLACK, i.e. isSquareAttacked(..., white) -- not !white.
        uint8 passSquare = kingside ? kingFrom + 1 : kingFrom - 1;
        if (
            isSquareAttacked(pos.board, kingFrom, white) || isSquareAttacked(pos.board, passSquare, white)
                || isSquareAttacked(pos.board, kingTo, white)
        ) {
            return (false, mr);
        }

        uint256 b = pos.board;
        uint8 king = getPiece(b, kingFrom);
        b = setPiece(b, kingFrom, EMPTY);
        b = setPiece(b, rookFrom, EMPTY);
        b = setPiece(b, kingTo, king);
        b = setPiece(b, rookTo, rook);

        mr.board = b;
        mr.castlingRights = pos.castlingRights & (white ? ~uint8(WK | WQ) : ~uint8(BK | BQ));
        mr.enPassantSquare = NO_EN_PASSANT;
        mr.isCapture = false;
        mr.isPawnMove = false;
        return (true, mr);
    }

    // ---------- top-level legality ----------

    function _pseudoLegalAndResult(Position memory pos, uint8 from, uint8 to, uint8 promo)
        private
        pure
        returns (bool ok, MoveResult memory mr)
    {
        if (from >= 64 || to >= 64 || from == to) return (false, mr);

        uint8 piece = getPiece(pos.board, from);
        if (piece == EMPTY) return (false, mr);

        bool moverIsBlack = isBlackPiece(piece);
        if (moverIsBlack == pos.whiteToMove) return (false, mr);

        uint8 target = getPiece(pos.board, to);
        if (target != EMPTY && isBlackPiece(target) == moverIsBlack) return (false, mr);

        uint8 ptype = pieceType(piece);

        if (ptype == KING) {
            int16 diff = int16(uint16(to)) - int16(uint16(from));
            if (diff == 2 || diff == -2) {
                return _tryCastle(pos, diff == 2);
            }
        }

        bool legalPattern = false;
        bool isEnPassantCapture = false;
        if (ptype == PAWN) {
            (legalPattern, isEnPassantCapture) = _isPawnPatternLegal(pos, from, to, target, moverIsBlack);
        } else if (ptype == KNIGHT) {
            legalPattern = _isKnightPattern(from, to);
        } else if (ptype == BISHOP) {
            legalPattern = _isBishopPattern(pos.board, from, to);
        } else if (ptype == ROOK) {
            legalPattern = _isRookPattern(pos.board, from, to);
        } else if (ptype == QUEEN) {
            legalPattern = _isRookPattern(pos.board, from, to) || _isBishopPattern(pos.board, from, to);
        } else if (ptype == KING) {
            legalPattern = _isKingPattern(from, to);
        }
        if (!legalPattern) return (false, mr);

        uint8 toRank = rankOf(to);
        bool isPromotion = (ptype == PAWN) && ((moverIsBlack && toRank == 0) || (!moverIsBlack && toRank == 7));
        if (isPromotion) {
            if (promo != KNIGHT && promo != BISHOP && promo != ROOK && promo != QUEEN) return (false, mr);
        } else {
            if (promo != 0) return (false, mr);
        }

        uint256 b = pos.board;
        bool isCapture = target != EMPTY;
        if (isEnPassantCapture) {
            uint8 capSq = rankOf(from) * 8 + fileOf(to);
            b = setPiece(b, capSq, EMPTY);
            isCapture = true;
        }
        b = setPiece(b, from, EMPTY);
        uint8 placedPiece = isPromotion ? (promo | (moverIsBlack ? BLACK_FLAG : 0)) : piece;
        b = setPiece(b, to, placedPiece);

        uint8 newRights = pos.castlingRights;
        if (ptype == KING) {
            newRights &= moverIsBlack ? ~uint8(BK | BQ) : ~uint8(WK | WQ);
        }
        if (from == 0 || to == 0) newRights &= ~uint8(WQ);
        if (from == 7 || to == 7) newRights &= ~uint8(WK);
        if (from == 56 || to == 56) newRights &= ~uint8(BQ);
        if (from == 63 || to == 63) newRights &= ~uint8(BK);

        uint8 newEnPassant = NO_EN_PASSANT;
        if (ptype == PAWN) {
            int16 rdiff = int16(uint16(rankOf(to))) - int16(uint16(rankOf(from)));
            if (rdiff == 2 || rdiff == -2) {
                newEnPassant = uint8(uint16(int16(uint16(from)) + (rdiff / 2) * 8));
            }
        }

        mr.board = b;
        mr.castlingRights = newRights;
        mr.enPassantSquare = newEnPassant;
        mr.isCapture = isCapture;
        mr.isPawnMove = (ptype == PAWN);
        return (true, mr);
    }

    /// @notice Full legality check: pseudo-legal movement pattern + own king not left in check.
    function isLegalMove(Position memory pos, uint8 from, uint8 to, uint8 promo)
        internal
        pure
        returns (bool legal, MoveResult memory mr)
    {
        (bool ok, MoveResult memory candidate) = _pseudoLegalAndResult(pos, from, to, promo);
        if (!ok) return (false, mr);
        bool moverBlack = !pos.whiteToMove;
        if (isInCheck(candidate.board, moverBlack)) return (false, mr);
        return (true, candidate);
    }

    /// @notice Does the side to move have at least one legal move anywhere on the board?
    /// Used to verify checkmate/stalemate claims atomically instead of trusting an unverified
    /// claim through an optimistic dispute window (see ChessGameTable.claimCheckmate/
    /// claimStalemate). Exhaustive 64x64 scan with a short-circuiting early return on the first
    /// legal move found -- cheap in the common case (a move usually turns up within the first
    /// few squares), bounded and measured expensive only in the true mate/stalemate case, which
    /// must exhaust the full search to prove none exists (empirically ~3.5-4.8M gas worst-case
    /// on a maximally adversarial 16-piece double-check position).
    /// @dev Every non-promotion move (including en passant, which is never a last-rank
    /// destination) is covered by the unconditional promo=0 call below; the promotion sub-loop
    /// is purely additive for the 4 non-zero promotion piece choices on a last-rank destination.
    function hasLegalMove(Position memory pos) internal pure returns (bool) {
        for (uint16 f = 0; f < 64; f++) {
            uint8 from = uint8(f);
            uint8 piece = getPiece(pos.board, from);
            if (piece == EMPTY) continue;
            if (isBlackPiece(piece) == pos.whiteToMove) continue;

            uint8 ptype = pieceType(piece);
            for (uint16 t = 0; t < 64; t++) {
                uint8 to = uint8(t);
                if (from == to) continue;

                (bool legal,) = isLegalMove(pos, from, to, 0);
                if (legal) return true;

                if (ptype == PAWN) {
                    uint8 toRank = rankOf(to);
                    if (toRank == 0 || toRank == 7) {
                        for (uint8 promo = KNIGHT; promo <= QUEEN; promo++) {
                            (bool legalP,) = isLegalMove(pos, from, to, promo);
                            if (legalP) return true;
                        }
                    }
                }
            }
        }
        return false;
    }
}
