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
    const vaultAddress = mainnet ? process.env.VAULT_MAIN : process.env.VAULT_TEST
    const strategyAddress = mainnet ? process.env.STRATEGY_MAIN : process.env.STRATEGY_TEST

    const vaultFactory: WaultBtcbVault__factory = new WaultBtcbVault__factory(deployer);
    let vault: WaultBtcbVault = await vaultFactory.attach(vaultAddress).connect(deployer);
    if ("redeploy" && true) {
        vault = await vaultFactory.deploy(btcbAddress);
    }
    console.log(`Deployed Vault... (${vault.address})`);
    const strategyFactory: WaultBtcbVenusStrategy__factory = new WaultBtcbVenusStrategy__factory(deployer);
    let strategy: WaultBtcbVenusStrategy = strategyFactory.attach(strategyAddress).connect(deployer);
    if ("redeploy" && true) {
        strategy = await strategyFactory.deploy(vault.address);
    }
    console.log(`Deployed Strategy... (${strategy.address})`);

    console.log("Setting strategy address...");
    await vault.setStrategy(strategy.address);
    console.log("Setting Wault reward factors...");
    const block = await ethers.getDefaultProvider(url).getBlockNumber();
    await vault.setWaultRewardFactors(parseEther('1000'), block, block+864000);
    if ("Disable Wault Reward" && false) {
        await vault.setWaultRewardMode(false);
    }
    // await strategy.setOnlyGov(false);
    
    const afterBalance = await deployer.getBalance();
    console.log(
        "Deployed cost:",
         (beforeBalance.sub(afterBalance)).toString()
    );
}

deploy()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    })