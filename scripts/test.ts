import * as hre from 'hardhat';
import { WaultBtcbVault } from '../types/ethers-contracts/WaultBtcbVault';
import { WaultBtcbVault__factory } from '../types/ethers-contracts/factories/WaultBtcbVault__factory';
import { WaultBtcbVenusStrategy } from '../types/ethers-contracts/WaultBtcbVenusStrategy';
import { WaultBtcbVenusStrategy__factory } from '../types/ethers-contracts/factories/WaultBtcbVenusStrategy__factory';
import { ERC20__factory } from '../types/ethers-contracts/factories/ERC20__factory';
import { assert } from 'sinon';

require("dotenv").config();

const { ethers } = hre;

const sleep = (milliseconds, msg='') => {
    console.log(`Wait ${milliseconds} ms... (${msg})`);
    const date = Date.now();
    let currentDate = null;
    do {
      currentDate = Date.now();
    } while (currentDate - date < milliseconds);
}

const toEther = (val) => {
    return ethers.utils.formatEther(val);
}

const parseEther = (val) => {
    return ethers.utils.parseEther(val);
}

async function deploy() {
    console.log((new Date()).toLocaleString());
    
    const [deployer] = await ethers.getSigners();
    
    console.log(
        "Deploying contracts with the account:",
        deployer.address
    );

    const beforeBalance = await deployer.getBalance();
    console.log("Account balance:", (await deployer.getBalance()).toString());

    const mainnet = process.env.NETWORK == "mainnet" ? true : false;
    const url = mainnet ? process.env.URL_MAIN : process.env.URL_TEST;
    const btcbAddress = mainnet ? process.env.BTCB_MAIN : process.env.BTCB_TEST
    const waultAddress = mainnet ? process.env.WAULT_MAIN : process.env.WAULT_TEST
    const vaultAddress = mainnet ? process.env.VAULT_MAIN : process.env.VAULT_TEST
    const strategyAddress = mainnet ? process.env.STRATEGY_MAIN : process.env.STRATEGY_TEST

    const vaultFactory: WaultBtcbVault__factory = new WaultBtcbVault__factory(deployer);
    const vault: WaultBtcbVault = await vaultFactory.attach(vaultAddress).connect(deployer);
    const strategyFactory: WaultBtcbVenusStrategy__factory = new WaultBtcbVenusStrategy__factory(deployer);
    const strategy: WaultBtcbVenusStrategy = await strategyFactory.attach(strategyAddress).connect(deployer);
    console.log(`Deployed Vault... (${vault.address})`);
    console.log(`Deployed Strategy... (${strategy.address})`);

    const erc20Factory = new ERC20__factory(deployer);
    const block = await ethers.getDefaultProvider(url).getBlockNumber();
    console.log("Block number: ", block);
    const btcb = await erc20Factory.attach(btcbAddress).connect(deployer);
    const btcbBalance = await btcb.balanceOf(strategy.address);
    console.log("btcbBalance: ", toEther(btcbBalance));
    const wault = await erc20Factory.attach(waultAddress).connect(deployer);
    const waultBalance = await wault.balanceOf(vault.address);
    console.log("waultBalance: ", toEther(waultBalance));

    console.log("waultRewardPerBlock: ", (await vault.waultRewardPerBlock()).toString());
    console.log("lastRewardBlock:", (await vault.lastRewardBlock()).toString());
    console.log("accWaultPerShare:", (await vault.accWaultPerShare()).toString());
    
    const totalSupply = await vault.totalSupply();
    console.log("totalSupply: ", toEther(totalSupply));
    const balanceOfUnderlying = await strategy.balanceOf();
    console.log("balanceOfUnderlying: ", toEther(balanceOfUnderlying));
    const balance = await vault.balance();
    console.log("balance: ", toEther(balance));
    const claimed = balance.gt(totalSupply) ? balance.sub(totalSupply) : 0;
    console.log("claimed: ", toEther(claimed));
    const pricePerShare = await vault.getPricePerFullShare();
    console.log("pricePerShare: ", toEther(pricePerShare));
    const user = '0xC627D743B1BfF30f853AE218396e6d47a4f34ceA';
    // const user = '0x61d7c6572922a1ecff8fce8b88920f7eaaab1dae';
    const balanceOf = await vault.balanceOf(user);
    console.log(`balanceOf: ${toEther(balanceOf)} (${user})`);
    const earned = balanceOf.mul(pricePerShare).sub(balanceOf.mul(parseEther('1'))).div(parseEther('1'));
    console.log("earned: ", toEther(earned));
    console.log("claimable: ", toEther(await vault.claimable(user)));

    const afterBalance = await deployer.getBalance();
    console.log(
        "Test cost:",
         (beforeBalance.sub(afterBalance)).toString()
    );
}

deploy()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    })