// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {ILiquidityContainer} from "../../../../../liquiditymanager/interfaces/ILiquidityContainer.sol";
import {IBurnMintERC20} from "../../../../../shared/token/ERC20/IBurnMintERC20.sol";

import {BurnMintERC20} from "../../../../../shared/token/ERC20/BurnMintERC20.sol";
import {Router} from "../../../../Router.sol";

import {TokenPool} from "../../../../pools/TokenPool.sol";
import {HybridLockReleaseUSDCTokenPool} from "../../../../pools/USDC/HybridLockReleaseUSDCTokenPool.sol";
import {USDCTokenPool} from "../../../../pools/USDC/USDCTokenPool.sol";
import {BaseTest} from "../../../BaseTest.t.sol";
import {MockE2EUSDCTransmitter} from "../../../mocks/MockE2EUSDCTransmitter.sol";
import {MockUSDCTokenMessenger} from "../../../mocks/MockUSDCTokenMessenger.sol";

contract USDCTokenPoolSetup is BaseTest {
  IBurnMintERC20 internal s_token;
  MockUSDCTokenMessenger internal s_mockUSDC;
  MockE2EUSDCTransmitter internal s_mockUSDCTransmitter;
  uint32 internal constant USDC_DEST_TOKEN_GAS = 150_000;

  struct USDCMessage {
    uint32 version;
    uint32 sourceDomain;
    uint32 destinationDomain;
    uint64 nonce;
    bytes32 sender;
    bytes32 recipient;
    bytes32 destinationCaller;
    bytes messageBody;
  }

  uint32 internal constant SOURCE_DOMAIN_IDENTIFIER = 0x02020202;
  uint32 internal constant DEST_DOMAIN_IDENTIFIER = 0;

  bytes32 internal constant SOURCE_CHAIN_TOKEN_SENDER = bytes32(uint256(uint160(0x01111111221)));
  address internal constant SOURCE_CHAIN_USDC_POOL = address(0x23789765456789);
  address internal constant DEST_CHAIN_USDC_POOL = address(0x987384873458734);
  address internal constant DEST_CHAIN_USDC_TOKEN = address(0x23598918358198766);

  address internal s_routerAllowedOnRamp = address(3456);
  address internal s_routerAllowedOffRamp = address(234);
  Router internal s_router;

  HybridLockReleaseUSDCTokenPool internal s_usdcTokenPool;
  HybridLockReleaseUSDCTokenPool internal s_usdcTokenPoolTransferLiquidity;
  address[] internal s_allowedList;

  function setUp() public virtual override {
    BaseTest.setUp();
    BurnMintERC20 usdcToken = new BurnMintERC20("LINK", "LNK", 18, 0, 0);
    s_token = usdcToken;
    deal(address(s_token), OWNER, type(uint256).max);
    _setUpRamps();

    s_mockUSDCTransmitter = new MockE2EUSDCTransmitter(0, DEST_DOMAIN_IDENTIFIER, address(s_token));
    s_mockUSDC = new MockUSDCTokenMessenger(0, address(s_mockUSDCTransmitter));

    usdcToken.grantMintAndBurnRoles(address(s_mockUSDCTransmitter));

    s_usdcTokenPool =
      new HybridLockReleaseUSDCTokenPool(s_mockUSDC, s_token, new address[](0), address(s_mockRMN), address(s_router));

    s_usdcTokenPoolTransferLiquidity =
      new HybridLockReleaseUSDCTokenPool(s_mockUSDC, s_token, new address[](0), address(s_mockRMN), address(s_router));

    usdcToken.grantMintAndBurnRoles(address(s_mockUSDC));
    usdcToken.grantMintAndBurnRoles(address(s_usdcTokenPool));

    TokenPool.ChainUpdate[] memory chainUpdates = new TokenPool.ChainUpdate[](2);
    chainUpdates[0] = TokenPool.ChainUpdate({
      remoteChainSelector: SOURCE_CHAIN_SELECTOR,
      remotePoolAddress: abi.encode(SOURCE_CHAIN_USDC_POOL),
      remoteTokenAddress: abi.encode(address(s_token)),
      allowed: true,
      outboundRateLimiterConfig: _getOutboundRateLimiterConfig(),
      inboundRateLimiterConfig: _getInboundRateLimiterConfig()
    });
    chainUpdates[1] = TokenPool.ChainUpdate({
      remoteChainSelector: DEST_CHAIN_SELECTOR,
      remotePoolAddress: abi.encode(DEST_CHAIN_USDC_POOL),
      remoteTokenAddress: abi.encode(DEST_CHAIN_USDC_TOKEN),
      allowed: true,
      outboundRateLimiterConfig: _getOutboundRateLimiterConfig(),
      inboundRateLimiterConfig: _getInboundRateLimiterConfig()
    });

    s_usdcTokenPool.applyChainUpdates(chainUpdates);

    USDCTokenPool.DomainUpdate[] memory domains = new USDCTokenPool.DomainUpdate[](1);
    domains[0] = USDCTokenPool.DomainUpdate({
      destChainSelector: DEST_CHAIN_SELECTOR,
      domainIdentifier: 9999,
      allowedCaller: keccak256("allowedCaller"),
      enabled: true
    });

    s_usdcTokenPool.setDomains(domains);

    vm.expectEmit();
    emit HybridLockReleaseUSDCTokenPool.LiquidityProviderSet(address(0), OWNER, DEST_CHAIN_SELECTOR);

    s_usdcTokenPool.setLiquidityProvider(DEST_CHAIN_SELECTOR, OWNER);
    s_usdcTokenPool.setLiquidityProvider(SOURCE_CHAIN_SELECTOR, OWNER);
  }

  function _setUpRamps() internal {
    s_router = new Router(address(s_token), address(s_mockRMN));

    Router.OnRamp[] memory onRampUpdates = new Router.OnRamp[](1);
    onRampUpdates[0] = Router.OnRamp({destChainSelector: DEST_CHAIN_SELECTOR, onRamp: s_routerAllowedOnRamp});
    Router.OffRamp[] memory offRampUpdates = new Router.OffRamp[](1);
    address[] memory offRamps = new address[](1);
    offRamps[0] = s_routerAllowedOffRamp;
    offRampUpdates[0] = Router.OffRamp({sourceChainSelector: SOURCE_CHAIN_SELECTOR, offRamp: offRamps[0]});

    s_router.applyRampUpdates(onRampUpdates, new Router.OffRamp[](0), offRampUpdates);
  }

  function _generateUSDCMessage(
    USDCMessage memory usdcMessage
  ) internal pure returns (bytes memory) {
    return abi.encodePacked(
      usdcMessage.version,
      usdcMessage.sourceDomain,
      usdcMessage.destinationDomain,
      usdcMessage.nonce,
      usdcMessage.sender,
      usdcMessage.recipient,
      usdcMessage.destinationCaller,
      usdcMessage.messageBody
    );
  }
}

contract HybridLockReleaseUSDCTokenPool_TransferLiquidity is USDCTokenPoolSetup {
  function test_transferLiquidity_Success() public {
    // Set as the OWNER so we can provide liquidity
    vm.startPrank(OWNER);

    s_usdcTokenPool.setLiquidityProvider(DEST_CHAIN_SELECTOR, OWNER);
    s_token.approve(address(s_usdcTokenPool), type(uint256).max);

    uint256 liquidityAmount = 1e9;

    // Provide some liquidity to the pool
    s_usdcTokenPool.provideLiquidity(DEST_CHAIN_SELECTOR, liquidityAmount);

    // Set the new token pool as the rebalancer
    s_usdcTokenPool.transferOwnership(address(s_usdcTokenPoolTransferLiquidity));

    vm.expectEmit();
    emit ILiquidityContainer.LiquidityRemoved(address(s_usdcTokenPoolTransferLiquidity), liquidityAmount);

    vm.expectEmit();
    emit HybridLockReleaseUSDCTokenPool.LiquidityTransferred(
      address(s_usdcTokenPool), DEST_CHAIN_SELECTOR, liquidityAmount
    );

    s_usdcTokenPoolTransferLiquidity.transferLiquidity(address(s_usdcTokenPool), DEST_CHAIN_SELECTOR);

    assertEq(
      s_usdcTokenPool.owner(),
      address(s_usdcTokenPoolTransferLiquidity),
      "Ownership of the old pool should be transferred to the new pool"
    );

    assertEq(
      s_usdcTokenPoolTransferLiquidity.getLockedTokensForChain(DEST_CHAIN_SELECTOR),
      liquidityAmount,
      "Tokens locked for dest chain doesn't match expected amount in storage"
    );

    assertEq(
      s_usdcTokenPool.getLockedTokensForChain(DEST_CHAIN_SELECTOR),
      0,
      "Tokens locked for dest chain in old token pool doesn't match expected amount in storage"
    );

    assertEq(
      s_token.balanceOf(address(s_usdcTokenPoolTransferLiquidity)),
      liquidityAmount,
      "Liquidity amount of tokens should be new in new pool, but aren't"
    );

    assertEq(
      s_token.balanceOf(address(s_usdcTokenPool)),
      0,
      "Liquidity amount of tokens should be zero in old pool, but aren't"
    );
  }

  function test_cannotTransferLiquidityDuringPendingMigration_Revert() public {
    // Set as the OWNER so we can provide liquidity
    vm.startPrank(OWNER);

    // Mark the destination chain as supporting CCTP, so use L/R instead.
    uint64[] memory destChainAdds = new uint64[](1);
    destChainAdds[0] = DEST_CHAIN_SELECTOR;

    s_usdcTokenPool.updateChainSelectorMechanisms(new uint64[](0), destChainAdds);

    s_usdcTokenPool.setLiquidityProvider(DEST_CHAIN_SELECTOR, OWNER);
    s_token.approve(address(s_usdcTokenPool), type(uint256).max);

    uint256 liquidityAmount = 1e9;

    // Provide some liquidity to the pool
    s_usdcTokenPool.provideLiquidity(DEST_CHAIN_SELECTOR, liquidityAmount);

    // Set the new token pool as the rebalancer
    s_usdcTokenPool.transferOwnership(address(s_usdcTokenPoolTransferLiquidity));

    s_usdcTokenPool.proposeCCTPMigration(DEST_CHAIN_SELECTOR);

    vm.expectRevert(
      abi.encodeWithSelector(HybridLockReleaseUSDCTokenPool.LanePausedForCCTPMigration.selector, DEST_CHAIN_SELECTOR)
    );

    s_usdcTokenPoolTransferLiquidity.transferLiquidity(address(s_usdcTokenPool), DEST_CHAIN_SELECTOR);
  }
}
