// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CentuariBondERC20} from "./CentuariBondERC20.sol";
import {DateTime} from "../../libraries/DateTime.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title CentuariBondERC20Factory
/// @notice Factory for deploying CentuariBondERC20 tokens for each market
/// @dev Uses CREATE2 for deterministic addresses based on (loanToken, maturity)
contract CentuariBondERC20Factory {
    // ============ Events ============

    /// @notice Emitted when a new bond token is created
    /// @param marketId The market identifier (keccak256 of loanToken and maturity)
    /// @param bondToken The deployed bond token address
    /// @param loanToken The underlying loan token
    /// @param maturity The maturity timestamp
    /// @param name The bond token name (e.g., "CBT USDC 1 Jan 2025")
    /// @param symbol The bond token symbol (e.g., "CBT-USDC-1JAN25")
    event BondTokenCreated(
        bytes32 indexed marketId,
        address indexed bondToken,
        address indexed loanToken,
        uint256 maturity,
        string name,
        string symbol
    );

    // ============ Errors ============

    /// @notice Thrown when caller is not the Centuari contract
    error OnlyCentuari();

    /// @notice Thrown when bond token already exists for this market
    error BondTokenAlreadyExists();

    /// @notice Thrown when bond token does not exist for this market
    error BondTokenDoesNotExist();

    // ============ Immutable Storage ============

    /// @notice The Centuari contract address (authorized to create bond tokens and mint)
    address public immutable CENTUARI;

    // ============ Storage ============

    /// @notice Mapping from marketId to bond token address
    /// @dev marketId = keccak256(abi.encode(loanToken, maturity))
    mapping(bytes32 => address) public bondTokens;

    // ============ Constructor ============

    /// @notice Creates the factory with the Centuari contract as the authorized creator
    /// @param centuari_ The Centuari contract address
    constructor(address centuari_) {
        CENTUARI = centuari_;
    }

    // ============ Modifiers ============

    /// @notice Restricts function access to the Centuari contract
    modifier onlyCentuari() {
        if (msg.sender != CENTUARI) revert OnlyCentuari();
        _;
    }

    // ============ External Functions ============

    /// @notice Get or create a bond token for a market
    /// @dev Creates a new bond token if one doesn't exist, otherwise returns existing
    /// @param loanToken The underlying loan token address
    /// @param maturity The maturity timestamp
    /// @return bondToken The bond token address
    function getOrCreate(address loanToken, uint256 maturity)
        external
        onlyCentuari
        returns (address bondToken)
    {
        bytes32 marketId = _getMarketId(loanToken, maturity);
        bondToken = bondTokens[marketId];

        if (bondToken == address(0)) {
            bondToken = _createBondToken(marketId, loanToken, maturity);
        }
    }

    /// @notice Get the bond token address for a market
    /// @param loanToken The underlying loan token address
    /// @param maturity The maturity timestamp
    /// @return The bond token address (address(0) if not created)
    function getBondToken(address loanToken, uint256 maturity)
        external
        view
        returns (address)
    {
        bytes32 marketId = _getMarketId(loanToken, maturity);
        return bondTokens[marketId];
    }

    /// @notice Compute the deterministic address for a bond token before deployment
    /// @param loanToken The underlying loan token address
    /// @param maturity The maturity timestamp
    /// @return The computed bond token address
    function computeBondTokenAddress(address loanToken, uint256 maturity)
        external
        view
        returns (address)
    {
        bytes32 marketId = _getMarketId(loanToken, maturity);
        bytes32 salt = marketId;

        // Get creation code with constructor args
        bytes memory bytecode = _getBytecode(loanToken, maturity);

        // Compute CREATE2 address
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode))
        );
        return address(uint160(uint256(hash)));
    }

    // ============ Internal Functions ============

    /// @notice Create a new bond token
    /// @param marketId The market identifier
    /// @param loanToken The underlying loan token address
    /// @param maturity The maturity timestamp
    /// @return bondToken The deployed bond token address
    function _createBondToken(bytes32 marketId, address loanToken, uint256 maturity)
        internal
        returns (address bondToken)
    {
        // Generate name and symbol
        string memory tokenSymbol = _getTokenSymbol(loanToken);
        string memory name = _generateName(tokenSymbol, maturity);
        string memory symbol = _generateSymbol(tokenSymbol, maturity);

        // Deploy using CREATE2 with marketId as salt
        bytes32 salt = marketId;
        CentuariBondERC20 token = new CentuariBondERC20{salt: salt}(
            name,
            symbol,
            CENTUARI,
            loanToken,
            maturity
        );

        bondToken = address(token);
        bondTokens[marketId] = bondToken;

        emit BondTokenCreated(marketId, bondToken, loanToken, maturity, name, symbol);
    }

    /// @notice Generate token name (e.g., "CBT USDC 1 Jan 2025")
    /// @param tokenSymbol The underlying token symbol
    /// @param maturity The maturity timestamp
    /// @return The generated name
    function _generateName(string memory tokenSymbol, uint256 maturity)
        internal
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked("CBT ", tokenSymbol, " ", DateTime.formatDate(maturity))
        );
    }

    /// @notice Generate token symbol (e.g., "CBT-USDC-1JAN25")
    /// @param tokenSymbol The underlying token symbol
    /// @param maturity The maturity timestamp
    /// @return The generated symbol
    function _generateSymbol(string memory tokenSymbol, uint256 maturity)
        internal
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked("CBT-", tokenSymbol, "-", DateTime.formatDateSymbol(maturity))
        );
    }

    /// @notice Get the symbol of a token, with safe handling for non-contract addresses
    /// @param token The token address
    /// @return The token symbol or "TOKEN" if unavailable
    function _getTokenSymbol(address token) internal view returns (string memory) {
        // If the address has no code (e.g., a plain EOA in tests), avoid calling symbol()
        // which would otherwise revert when decoding empty return data.
        if (token.code.length == 0) {
            return "TOKEN";
        }

        try IERC20Metadata(token).symbol() returns (string memory symbol) {
            return symbol;
        } catch {
            return "TOKEN";
        }
    }

    /// @notice Calculate market ID from loan token and maturity
    /// @param loanToken The loan token address
    /// @param maturity The maturity timestamp
    /// @return The market ID
    function _getMarketId(address loanToken, uint256 maturity) internal pure returns (bytes32) {
        return keccak256(abi.encode(loanToken, maturity));
    }

    /// @notice Get the bytecode for CREATE2 address computation
    /// @param loanToken The underlying loan token address
    /// @param maturity The maturity timestamp
    /// @return The creation bytecode with constructor args
    function _getBytecode(address loanToken, uint256 maturity)
        internal
        view
        returns (bytes memory)
    {
        string memory tokenSymbol = _getTokenSymbol(loanToken);
        string memory name = _generateName(tokenSymbol, maturity);
        string memory symbol = _generateSymbol(tokenSymbol, maturity);

        return abi.encodePacked(
            type(CentuariBondERC20).creationCode,
            abi.encode(name, symbol, CENTUARI, loanToken, maturity)
        );
    }
}

