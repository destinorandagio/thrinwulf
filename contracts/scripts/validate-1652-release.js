const fs=require("fs"),path=require("path"),crypto=require("crypto");
const root=process.argv[2]||"nft-assets/metadata",manifest=JSON.parse(fs.readFileSync(path.join(root,"release-manifest.json"),"utf8"));
if(manifest.maxSupply!==1652||manifest.readerBonusCap!==165)throw new Error("Wrong release constants");
const expected={Common:826,Uncommon:413,Rare:248,Epic:99,Legendary:49,Mythic:16,Unicorn:1},counts={},images=new Set(),hashes={};
for(let id=1;id<=1652;id++){const file=path.join(root,`${id}.json`);if(!fs.existsSync(file))throw new Error(`Missing ${id}.json`);const raw=fs.readFileSync(file),m=JSON.parse(raw);if(!String(m.image||"").startsWith("ipfs://"))throw new Error(`Invalid image URI ${id}`);if(images.has(m.image))throw new Error(`Duplicate final image URI ${m.image}`);images.add(m.image);const tier=m.attributes?.find(a=>a.trait_type==="Rarity")?.value;if(!expected[tier])throw new Error(`Invalid rarity ${id}`);counts[tier]=(counts[tier]||0)+1;hashes[`${id}.json`]=crypto.createHash("sha256").update(raw).digest("hex");}
for(const [tier,count] of Object.entries(expected))if(counts[tier]!==count)throw new Error(`${tier}: ${counts[tier]} != ${count}`);
fs.writeFileSync(path.join(root,"sha256-manifest.json"),JSON.stringify({format:"THRINWULF_1652_SHA256_V1",files:hashes},null,2)+"\n");
console.log(JSON.stringify({status:"PASS",tokens:1652,uniqueImages:images.size,rarityCounts:counts,unicornTokenId:manifest.unicornTokenId},null,2));
