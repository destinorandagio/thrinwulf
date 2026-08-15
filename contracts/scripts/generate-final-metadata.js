const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

const MAX_SUPPLY = 1652;
const PAID_CAP = 1487;
const COUNTS = {Common:826,Uncommon:413,Rare:248,Epic:99,Legendary:49,Mythic:16,Unicorn:1};
const ORDER = Object.keys(COUNTS);

function required(name){const value=process.env[name];if(!value)throw new Error(`Missing ${name}`);return value;}
function csvLine(line){
  const values=[];let value="",quoted=false;
  for(let i=0;i<line.length;i++){
    const char=line[i];
    if(char==='"'){
      if(quoted&&line[i+1]==='"'){value+='"';i++;}
      else quoted=!quoted;
    }else if(char===','&&!quoted){values.push(value.trim());value="";}
    else value+=char;
  }
  if(quoted)throw new Error(`Unclosed quote in CSV row: ${line}`);
  values.push(value.trim());
  return values;
}
function tierForSlot(slot){if(slot<=826)return "Common";if(slot<=1239)return "Uncommon";if(slot<=1487)return "Rare";if(slot<=1586)return "Epic";if(slot<=1635)return "Legendary";if(slot<=1651)return "Mythic";return "Unicorn";}

const source=process.argv[2]||"nft-assets/final-manifest.csv";
const output=process.argv[3]||"nft-assets/metadata";
const seed=required("RARITY_SEED");
const collection=required("COLLECTION_ADDRESS");
if(!ethers.isHexString(seed,32)||!ethers.isAddress(collection))throw new Error("Invalid seed or collection address");
const commitment=ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["bytes32"],[seed]));
const hash=ethers.keccak256(ethers.solidityPacked(["bytes32","address"],[seed,collection]));
const offset=165+(Number(BigInt(hash)%1487n));
const unicornTokenId=MAX_SUPPLY-offset;
if(unicornTokenId<1||unicornTokenId>PAID_CAP)throw new Error("Unicorn escaped paid allocation");

const lines=fs.readFileSync(source,"utf8").replace(/^\uFEFF/,"").trim().split(/\r?\n/);
const header=csvLine(lines.shift());
const index=Object.fromEntries(header.map((v,i)=>[v,i]));
for(const key of ["asset_id","rarity","image_uri","name","description"])if(index[key]===undefined)throw new Error(`Missing CSV column ${key}`);
const pools=Object.fromEntries(ORDER.map(t=>[t,[]]));
const ids=new Set(),uris=new Set();
for(const line of lines){const row=csvLine(line),tier=row[index.rarity];if(!pools[tier])throw new Error(`Invalid rarity ${tier}`);const id=row[index.asset_id],uri=row[index.image_uri];if(!id||ids.has(id))throw new Error(`Duplicate/empty asset_id ${id}`);if(!uri.startsWith("ipfs://")||uris.has(uri))throw new Error(`Invalid/duplicate image_uri ${uri}`);ids.add(id);uris.add(uri);pools[tier].push({id,uri,name:row[index.name],description:row[index.description]});}
for(const tier of ORDER)if(pools[tier].length!==COUNTS[tier])throw new Error(`${tier}: expected ${COUNTS[tier]}, got ${pools[tier].length}`);

fs.mkdirSync(output,{recursive:true});const assigned={};
for(let tokenId=1;tokenId<=MAX_SUPPLY;tokenId++){
  const slot=((tokenId-1+offset)%MAX_SUPPLY)+1,tier=tierForSlot(slot),asset=pools[tier].shift();
  const metadata={name:asset.name||`THRINWULF Portal #${String(tokenId).padStart(4,"0")}`,description:asset.description||"An official Dawn of the Delta Portal from Book I of THRINWULF.",image:asset.uri,external_url:`https://thrinwulf.com/portal/${tokenId}`,attributes:[{trait_type:"Collection",value:"Dawn of the Delta"},{trait_type:"Book",value:"Book I"},{trait_type:"Rarity",value:tier},{trait_type:"Portal",value:tokenId}]};
  fs.writeFileSync(path.join(output,`${tokenId}.json`),JSON.stringify(metadata,null,2)+"\n");assigned[tokenId]={asset_id:asset.id,rarity:tier,image_uri:asset.uri};
}
const report={format:"THRINWULF_1652_METADATA_V1",maxSupply:MAX_SUPPLY,paidCap:PAID_CAP,readerBonusCap:165,rarityCounts:COUNTS,rarityCommitment:commitment,rarityOffset:offset,unicornTokenId,collectionAddress:collection,assigned};
fs.writeFileSync(path.join(output,"release-manifest.json"),JSON.stringify(report,null,2)+"\n");
console.log(JSON.stringify({...report,assigned:undefined},null,2));
