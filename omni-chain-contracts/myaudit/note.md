## this seems to be a dex
- to submit in sherlock: root cause, impact, attack path , Poc if it is complicated
### GatewaySend 
DepositAndcall() public

onCall() , onRevert() onlyGateway:Zetachain gateways like GatewayEVM, GatewayZEVM

### GateWayCrossChain 
- deployed on zetachain and implements universalContract interface
- manage fees and refund mechanisms
- handle swaps within zetachain

### GatewayTransferNative
- like Gatewaycrosschain but for native zetachain txs
- for swap between ZRC20 and ZETA tokens

### DoDo Route Proxy (out of scope)
mixswap()

### GatewayEVM and GateWayZEVM



### Zetachain vs Layerzero
- ZetaChain is platform which provide crosschain where protocols don't need to deploy contracts on every chain
- LayerZero is a protocol on which configed contracts on every chain use to communicate
- Hyperconnected nodes on zetachain monitor chains through their gateway and then execute tx on omnichain smart contracts


### simple flow
user > GatewaySend::depositAndCall()on chain A > zetachain > GatewaySend::onCall() on Chain B > if revert: GateWaySend::onRevert() on chain A

