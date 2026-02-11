#!/usr/bin/env node
import { ethers } from "ethers";

const [registryAddress, taskIndex, rpcUrl] = process.argv.slice(2);

if (!registryAddress || !taskIndex || !rpcUrl) {
    console.error("Usage: node getTaskDetails.js <registryAddress> <taskIndex> <rpcUrl>");
    process.exit(1);
}

// Replace with your contract ABI (minimal, only getTaskDetails)
const registryAbi = [
    "function getTaskDetails(uint64 _taskIndex) view returns (tuple(uint128 maxGasAmount,uint128 gasPriceCap,uint128 automationFeeCapForCycle,uint128 lockedFeeForNextCycle,bytes32 txHash,uint64 taskIndex,uint64 registrationTime,uint64 expiryTime,uint64 priority,uint8 taskType,uint8 state,address owner,bytes payloadTx,bytes[] auxData))"
];

const provider = new ethers.JsonRpcProvider(rpcUrl);
const registry = new ethers.Contract(registryAddress, registryAbi, provider);

async function main() {
    try {
        const task = await registry.getTaskDetails(taskIndex);
        console.log(`taskIndex: ${task.taskIndex}`);
        console.log(`owner: ${task.owner}`);
        console.log(`state: ${["PENDING","ACTIVE","CANCELLED"][task.state]}`);
        console.log(`expiryTime: ${task.expiryTime}`);
        console.log(`payloadTx: ${task.payloadTx}`);
        console.log(`auxData: ${task.auxData}`);
        console.log(`maxGasAmount: ${task.maxGasAmount}`);
        console.log(`gasPriceCap: ${task.gasPriceCap}`);
        console.log(`automationFeeCapForCycle: ${task.automationFeeCapForCycle}`);
        console.log(`lockedFeeForNextCycle: ${task.lockedFeeForNextCycle}`);
    } catch (e) {
        console.error("Error fetching task:", e.message);
    }
}

main();
