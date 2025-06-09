// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GatewayEVM} from "@zetachain/protocol-contracts/contracts/evm/GatewayEVM.sol";
import "@zetachain/protocol-contracts/contracts/evm/interfaces/IGatewayEVM.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {IDODORouteProxy} from "./interfaces/IDODORouteProxy.sol";
import "./libraries/SwapDataHelperLib.sol";

contract GatewaySend is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    address constant _ETH_ADDRESS_ = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 public globalNonce; //@>i increment with each crosschain tx
    uint256 public gasLimit;
    address public DODORouteProxy;
    address public DODOApprove;
    GatewayEVM public gateway; //@>i Entry point to ZetaChain's cross-chain messaging system
    
    event EddyCrossChainRevert(
        bytes32 externalId,
        address token,
        uint256 amount,
        address walletAddress
    );
    event EddyCrossChainSend(
        bytes32 externalId,
        uint32 dstChainId,
        address fromToken,
        address toToken,
        uint256 amount,
        uint256 outputAmount,
        address walletAddress,
        bytes payload
    );
    event EddyCrossChainReceive(
        bytes32 externalId,
        address fromToken,
        address toToken,
        uint256 amount,
        uint256 outputAmount,
        address walletAddress,
        bytes payload
    );
    event DODORouteProxyUpdated(address dodoRouteProxy);
    event GatewayUpdated(address gateway);

    error Unauthorized();
    error RouteProxyCallFailed();

    modifier onlyGateway() {
        if (msg.sender != address(gateway)) revert Unauthorized();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract
     * @param _gateway Gateway contract address
     * @param _dodoRouteProxy Address of the DODORouteProxy
     */
    function initialize(
        address payable _gateway,
        address _dodoRouteProxy,
        address _dodoApprove,
        uint256 _gasLimit
    ) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        gateway = GatewayEVM(_gateway);
        DODORouteProxy = _dodoRouteProxy;
        DODOApprove = _dodoApprove;
        gasLimit = _gasLimit;
    }

    function setOwner(address _owner) external onlyOwner {
        transferOwnership(_owner);
    }

    function setDODORouteProxy(address _dodoRouteProxy) external onlyOwner {
        DODORouteProxy = _dodoRouteProxy;
        emit DODORouteProxyUpdated(_dodoRouteProxy);
    }

    function setGateway(address _gateway) external onlyOwner {
        gateway = GatewayEVM(_gateway);
        emit GatewayUpdated(_gateway);
    }

    function setGasLimit(uint256 _gasLimit) external onlyOwner {
        gasLimit = _gasLimit;
    }
 
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
 //======================================================================


    //@>q can anyone exploit this pure function? who use this calcualtions?
    function concatBytes(bytes32 a, bytes memory b) public pure returns (bytes memory) {
        bytes memory result = new bytes(32 + b.length);
        uint k = 0;
        for (uint i = 0; i < 32; i++) {
            result[k++] = a[i];
        }
        for (uint i = 0; i < b.length; i++) {
            result[k++] = b[i];
        }
        return result;
    }
    //@>i decode encoded crosschain messages
    /* @>i packedMessage = crosschainData(need to be unpacked) + other data
    message:
    [externalId: 32 bytes][outputAmount: 32 bytes][receiverLen: 2 bytes][crossChainDataLen: 2 bytes][receiver: variable][crossChainData: variable]
    crosschaindata:
    [tokenA: 20 bytes][tokenB: 20 bytes][swapDataB: remaining bytes]
    */

   //@>audit silent corruption - unexpected values might pass through the system without triggering errors until they cause downstream failures that are difficult to diagnose
    function decodePackedMessage(
        bytes calldata message
    ) internal pure returns (
        bytes32 externalId, 
        uint256 outputAmount, 
        bytes calldata receiver, 
        address fromToken, 
        address toToken, 
        bytes calldata swapDataB
    ) {
        uint16 receiverLen;
        uint16 crossChainDataLen;
        bytes calldata crossChainData;
        //@>q how does calldata load work? can read beyond the bounds of calldata? no verification of message before loading
        //@>i slicing calldata. offset is 0 probably. calldataload will load 32 bytes
        assembly {
            externalId := calldataload(message.offset) // first 32 bytes
            outputAmount := calldataload(add(message.offset, 32)) // next 32 bytes
            receiverLen := shr(240, calldataload(add(message.offset, 64))) // 2 bytes
            crossChainDataLen := shr(240, calldataload(add(message.offset, 66))) // 2 bytes
        }
         //@>audit No validation that offset + receiverLen or offset + crossChainDataLen are within bounds
        uint offset = 68; // starting point of receiver
        receiver = message[offset : offset + receiverLen];
        offset += receiverLen;
        crossChainData = message[offset : offset + crossChainDataLen];

        (fromToken, toToken, swapDataB) = decodePackedData(crossChainData);
    }
    //@>i decode swap data
    function decodePackedData(bytes calldata data) internal pure returns (
        address tokenA,
        address tokenB,
        bytes calldata swapDataB
    ) {

        //@>audit Assumes data is at least 40 bytes long with no explicit check
        //@>audit No validation that resulting addresses are valid

        assembly {
            tokenA := shr(96, calldataload(data.offset))
            tokenB := shr(96, calldataload(add(data.offset, 20)))
        }

        if (data.length > 40) {
            swapDataB = data[40:];
        } else {
            swapDataB = data[0:0]; // empty slice
        }
    }

    //@>i Generates unique transaction ID	
    function _calcExternalId(address sender) internal view returns (bytes32 externalId) {
        //@>q can this abi.encodePacked() lead to a collision or same ids for different tx
        externalId = keccak256(abi.encodePacked(address(this), sender, globalNonce, block.timestamp));
    }

  //@>i handles eth deposit to gatway
    function _handleETHDeposit(
        address targetContract,
        uint256 amount,
        bytes memory message,
        RevertOptions memory revertOptions
    ) internal {
        gateway.depositAndCall{value: amount}(
            targetContract,
            message,
            revertOptions
        );
    }
    
    //@>i handles erc20 token deposit to gateway
    function _handleERC20Deposit(
        address targetContract,
        uint256 amount,
        address asset,
        bytes memory message,
        RevertOptions memory revertOptions
    ) internal {
        IERC20(asset).approve(address(gateway), amount);
       //@>i call zetachain gateway
        gateway.depositAndCall(
            targetContract,
            amount,
            asset,
            message,
            revertOptions
        );
    }
  

    //@>i Performs token swap via DODO	
    function _doMixSwap(bytes calldata swapData) internal returns (uint256) {
        MixSwapParams memory params = SwapDataHelperLib.decodeCompressedMixSwapParams(swapData);

        if(params.fromToken != _ETH_ADDRESS_) {
            IERC20(params.fromToken).approve(DODOApprove, params.fromTokenAmount);
        }

        return IDODORouteProxy(DODORouteProxy).mixSwap{value: msg.value}(
            params.fromToken,
            params.toToken,
            params.fromTokenAmount,
            params.expReturnAmount,
            params.minReturnAmount,
            params.mixAdapters,
            params.mixPairs,
            params.assetTo,
            params.directions,
            params.moreInfo,
            params.feeData,
            params.deadline
        );
    }


    //@>i Initiates cross-chain transfer with swap
    function depositAndCall(
        address fromToken,
        uint256 amount,
        bytes calldata swapData,
        address targetContract,
        address asset,
        uint32 dstChainId,
        bytes calldata payload
    ) public payable {

        globalNonce++; //@>q is this global in this contract and all transactions in this contract?
        //@>q can anything bad happens when we first increment this globalNonce?

        bytes32 externalId = _calcExternalId(msg.sender);

        bool fromIsETH = (fromToken == _ETH_ADDRESS_);

        // Handle input token
        if(fromIsETH) {
            require(
                msg.value >= amount, 
                "INSUFFICIENT AMOUNT: ETH NOT ENOUGH"
            );
        } else {
            require(
                IERC20(fromToken).transferFrom(msg.sender, address(this), amount), 
                "INSUFFICIENT AMOUNT: ERC20 TRANSFER FROM FAILED"
            );
        }
         
        // Swap on DODO Router
        uint256 outputAmount = _doMixSwap(swapData);

        // Construct message and revert options
        bytes memory message = concatBytes(externalId, payload);
        RevertOptions memory revertOptions = RevertOptions({
            revertAddress: address(this),
            callOnRevert: true,
            abortAddress: targetContract,
            revertMessage: bytes.concat(externalId, bytes20(msg.sender)),
            onRevertGasLimit: gasLimit
        });

        bool toIsETH = (asset == _ETH_ADDRESS_);
        if (toIsETH) {
            _handleETHDeposit(
                targetContract,
                outputAmount,
                message,
                revertOptions
            );
        } else {
            _handleERC20Deposit(
                targetContract,
                outputAmount,
                asset,
                message,
                revertOptions
            );
        }

        emit EddyCrossChainSend(
            externalId,
            dstChainId,
            fromToken,
            asset,
            amount,
            outputAmount,
            msg.sender,
            message
        );
    }
   
   //@>i Initiates direct cross-chain transfer without swap	
   //@>q as this function doesn't limit the payload, can someone use a big payload and disrupt the protocol?
    function depositAndCall(
        address targetContract,
        uint256 amount,
        address asset,
        uint32 dstChainId,
        bytes calldata payload
    ) public payable {
        globalNonce++;
        //@>i the unique ID across all chains
        bytes32 externalId = _calcExternalId(msg.sender); 

        bool isETH = (asset == _ETH_ADDRESS_);

        bytes memory message = concatBytes(externalId, payload);

        RevertOptions memory revertOptions = RevertOptions({
            revertAddress: address(this), //@>i refund is go to this gateway and then in onrevert transfered to user
            callOnRevert: true,
            abortAddress: targetContract,
            revertMessage: bytes.concat(externalId, bytes20(msg.sender)),
            onRevertGasLimit: gasLimit
        });

        //@>audit if someone send a big amount of eth but determines only a tiny amount and if the fee is calculated based on the amount, user can avoid fees. but we should see what happens to the msg.value sent

        if (isETH) {
            require(msg.value >= amount, "INSUFFICIENT AMOUNT: ETH NOT ENOUGH");
            _handleETHDeposit(
                targetContract, 
                msg.value, //@>q why they used msg.value instead of amount?
                message, 
                revertOptions
            );
        } else {
            require(
                IERC20(asset).transferFrom(msg.sender, address(this), amount),
                "INSUFFICIENT AMOUNT: ERC20 TRANSFER FROM FAILED"
            );
            _handleERC20Deposit(
                targetContract, 
                amount,
                asset, 
                message, 
                revertOptions
            );
        }
        //@>i use externalId to explore the tx
        emit EddyCrossChainSend(
            externalId,
            dstChainId,
            asset,
            asset,
            amount,
            amount,
            msg.sender,
            message
        );
    }


   //@>i Receives and processes incoming cross-chain messages	
   //@>q what are devs assumptions in this funcion? 
   //@>i gateways are trusted
    function onCall(
        MessageContext calldata /*context*/,
        bytes calldata message
    ) external payable onlyGateway returns (bytes4) {
        (
            bytes32 externalId, 
            uint256 amount, 
            bytes calldata recipient, 
            address fromToken, 
            address toToken, 
            bytes calldata swapData
        ) = decodePackedMessage(message);

        //@>audit The protocol should implement explicit length validation and address format checks before executing any asset transfers.

        bool fromIsETH = (fromToken == _ETH_ADDRESS_);
        bool toIsETH = (toToken == _ETH_ADDRESS_);
        address evmWalletAddress = address(bytes20(recipient));
        //@>i if it is ETH, it is send with the function call trough msg.value
        //@>audit there is no check if received value == amount 
        if(!fromIsETH) {
            //@>q does the this contract has the approval for transfer from zeta gateway to himeself?
            IERC20(fromToken).transferFrom(msg.sender, address(this), amount);
        }

        uint256 outputAmount;
        if(fromToken == toToken) {
            outputAmount = amount;
        } else {
            outputAmount = _doMixSwap(swapData);
        }

        if(toIsETH) {
            payable(evmWalletAddress).transfer(outputAmount);
        } else {
            //@>audit: should use safetransfer
            IERC20(toToken).transfer(evmWalletAddress, outputAmount);
        }
        
        emit EddyCrossChainReceive(
            externalId,
            fromToken,
            toToken,
            amount,
            outputAmount,
            evmWalletAddress,
            message
        );

        return "";
    }

    /**
     * @notice Function called by the gateway to revert the cross-chain swap
     * @param context Revert context
     * @dev Only the gateway can call this function
     */
    //@>i is called to refund the locked sent amount 
    function onRevert(RevertContext calldata context) external onlyGateway {
        bytes32 externalId = bytes32(context.revertMessage[0:32]);
        address sender = address(uint160(bytes20(context.revertMessage[32:])));

        //@>i transfer refund amount - fee of the context from this to sender
        TransferHelper.safeTransfer(context.asset, sender, context.amount);
        
        emit EddyCrossChainRevert(
            externalId,
            context.asset,
            context.amount,
            sender
        );
    }

    receive() external payable {}

    fallback() external payable {}
}