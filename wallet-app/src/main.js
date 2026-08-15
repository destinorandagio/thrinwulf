import * as ethers from 'ethers';
import {createAppKit} from '@reown/appkit';
import {EthersAdapter} from '@reown/appkit-adapter-ethers';
import {polygon} from '@reown/appkit/networks';
window.THR_ETHERS=ethers;
const projectId=window.THR_CONFIG?.polygon?.reownProjectId;
if(projectId){
  const appKit=createAppKit({
    adapters:[new EthersAdapter()],
    networks:[polygon],
    defaultNetwork:polygon,
    projectId,
    metadata:{name:'THRINWULF',description:'Official THRINWULF DApp',url:location.origin,icons:[location.origin+'/assets/img/collection-logo.png']},
    themeMode:'dark',
    themeVariables:{'--w3m-accent':'#D4AF37','--w3m-border-radius-master':'2px'}
  });
  window.THR_APPKIT=appKit;
  window.THR_OPEN_APPKIT=()=>appKit.open();
}
