require('@nomicfoundation/hardhat-toolbox');
const path=require('path');
const {TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD}=require('hardhat/builtin-tasks/task-names');
subtask(TASK_COMPILE_SOLIDITY_GET_SOLC_BUILD,async(args,_hre,runSuper)=>{
 if(args.solcVersion==='0.8.28') return {compilerPath:path.join(__dirname,'node_modules/solc/soljson.js'),isSolcJs:true,version:'0.8.28',longVersion:require('solc').version()};
 return runSuper(args);
});
module.exports={solidity:{version:'0.8.28',settings:{optimizer:{enabled:true,runs:300},evmVersion:'paris'}},networks:{polygon:{url:process.env.POLYGON_RPC||'',accounts:process.env.DEPLOYER_KEY?[process.env.DEPLOYER_KEY]:[],chainId:137},amoy:{url:process.env.AMOY_RPC||'https://rpc-amoy.polygon.technology',accounts:process.env.DEPLOYER_KEY?[process.env.DEPLOYER_KEY]:[],chainId:80002}}};
