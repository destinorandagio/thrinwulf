const fs=require('fs');
const path=require('path');
const file=process.argv[2];
const target=process.argv[3]||'amoy';
if(!file) throw new Error('Evidence JSON path required');
const full=path.resolve(file);
const data=JSON.parse(fs.readFileSync(full,'utf8'));
const keys=Array.from({length:12},(_,i)=>`C${String(i+1).padStart(2,'0')}_`);
const entries=Object.entries(data.controls||{});
const expected={Common:826,Uncommon:413,Rare:248,Epic:99,Legendary:49,Mythic:16,Unicorn:1};
const c=data.collection||{};
if(c.architecture!=='THRINWULF_1652_V1'||c.max_supply!==1652||c.paid_cap!==1487||c.reader_bonus_cap!==165||c.final_unique_images!==1652||c.shared_mystery_assets!==1||c.shared_pre_reveal_assets!==1)throw new Error('Release evidence does not match THRINWULF 1,652 architecture');
if(!c.rarity_counts||Object.keys(expected).some(key=>c.rarity_counts[key]!==expected[key])||Object.keys(c.rarity_counts).some(key=>expected[key]===undefined))throw new Error('Release evidence rarity counts are not exact');
for(const prefix of keys){const hit=entries.find(([k])=>k.startsWith(prefix));if(!hit)throw new Error(`Missing ${prefix} control`);if(hit[1]!==true)throw new Error(`${hit[0]} is not approved`);}
if(target==='polygon'){
 if(!/^[0-9a-f]{40}$/i.test(data.source_commit||'')) throw new Error('Mainnet evidence requires an exact source commit');
 const external=['C06_','C07_','C08_','C09_','C10_','C11_','C12_'];
 for(const prefix of external){const key=entries.find(([k])=>k.startsWith(prefix))[0];if(!(data.evidence_urls||{})[key])throw new Error(`Mainnet evidence URL missing for ${key}`);}
}
console.log(`12/12 release controls approved for ${target}`);
