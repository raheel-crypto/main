import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { salesforce } from '@salesforce/vite-plugin-ui-bundle';
import tailwindcss from '@tailwindcss/vite';
import path from 'path';

export default defineConfig({
  plugins: [
    salesforce(),
    react(),
    tailwindcss(),
  ],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
});
