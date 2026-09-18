# Blockchess Smart Contracts

This repository contains only the smart contract source code for **Blockchess**. It is a standalone repository and archive that does not include the indexer or frontend application, which are maintained in separate repositories.

## Overview

**Blockchess** is a fully on-chain chess protocol with monetary stakes on every move. All chess rules—including legal move validation, castling, en passant, pawn promotion, the 50-move rule, threefold repetition, checkmate, and stalemate—are evaluated directly inside the smart contract without relying on backend infrastructure or external oracles.

## Smart Contracts

- **`ChessGameFactory.sol`**: Deploys cheap EIP-1167 proxy table clones, manages the allowlist of ERC20 staking tokens, and configures protocol fees.
- **`ChessGameTable.sol`**: Main table engine managing moves, stakes, timers, move undo and stake raise proposals, game outcome determination, and pull-based payouts.
- **`ChessEloRegistry.sol`**: Independent ELO rating tracker for Duel games that is unbound to specific tables and can be invoked permissionlessly after a game.
- **`libraries/ChessEngine.sol`**: Pure chess rule library responsible for legal move generation and detecting check, checkmate, and stalemate.
- **`libraries/PositionHash.sol`**: Hashes board positions for tracking position repetitions.

## Deployed Addresses (Polygon PoS Mainnet, Chain ID: 137)

| Contract | Address | Verification Status & Links |
| :--- | :--- | :--- |
| **ChessGameFactory** | `0x532408070454D13ED7Ef142fb0Fb86247ea3d7E0` | • [Blockscout](https://polygon.blockscout.com/address/0x532408070454D13ED7Ef142fb0Fb86247ea3d7E0#code)<br>• [Sourcify](https://repo.sourcify.dev/137/0x532408070454D13ED7Ef142fb0Fb86247ea3d7E0/) (Full match creation + runtime bytecode)<br>• *Polygonscan*: Fails to verify there despite the identical source and settings verifying cleanly on Blockscout and Sourcify. Repeated attempts point to how Polygonscan's verifier handles an immutable variable set via an internal `new ChessGameTable()` call in the constructor, but this is our own diagnosis from testing, not a documented Polygonscan issue. |
| **ChessEloRegistry** | `0xFf8AC12617793a41a9Bf392971300F5cbE41e534` | • [Blockscout](https://polygon.blockscout.com/address/0xFf8AC12617793a41a9Bf392971300F5cbE41e534#code)<br>• [Sourcify](https://repo.sourcify.dev/137/0xFf8AC12617793a41a9Bf392971300F5cbE41e534/) (Full match)<br>• [Polygonscan](https://polygonscan.com/address/0xFf8AC12617793a41a9Bf392971300F5cbE41e534#code) |
| **ChessGameTable** *(Implementation)* | `0xEea851487Aacc9FC430a22e7D34Fd6A9bD2eb950` | • [Blockscout](https://polygon.blockscout.com/address/0xEea851487Aacc9FC430a22e7D34Fd6A9bD2eb950#code)<br>• [Sourcify](https://repo.sourcify.dev/137/0xEea851487Aacc9FC430a22e7D34Fd6A9bD2eb950/) (Full match)<br>• [Polygonscan](https://polygonscan.com/address/0xEea851487Aacc9FC430a22e7D34Fd6A9bD2eb950#code) |

## Security Notice

> [!WARNING]
> These contracts have not undergone an independent security audit. Consider the possible risks and use them at your own risk.

## License

This project is licensed under the [MIT License](LICENSE) (each source file contains `SPDX-License-Identifier: MIT`).
