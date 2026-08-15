import {defineConfig} from 'vite';
export default defineConfig({build:{outDir:'../public/assets/wallet',emptyOutDir:true,rollupOptions:{input:'./src/main.js',output:{entryFileNames:'appkit.js',chunkFileNames:'chunk-[hash].js',assetFileNames:'asset-[hash][extname]'}}}});
