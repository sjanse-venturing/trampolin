// Puente seguro entre la interfaz y el proceso principal (contextIsolation + sandbox).
// Solo expone las operaciones de la API de Trampolín Remaster (ver src/shared/ipc.ts).
const { contextBridge, ipcRenderer } = require('electron');

const invoke = (channel) => (...args) => ipcRenderer.invoke(channel, ...args);

contextBridge.exposeInMainWorld('remaster', {
  getState: invoke('state'),
  chooseFolder: invoke('chooseFolder'),
  chooseIso: invoke('chooseIso'),
  scanFolder: invoke('scanFolder'),
  importIsos: invoke('importIsos'),
  onProgress: (cb) => {
    ipcRenderer.removeAllListeners('progress');
    ipcRenderer.on('progress', (_e, percent, message) => cb(percent, message));
  },
  removeGame: invoke('removeGame'),
  relocateGame: invoke('relocateGame'),
  updateSettings: invoke('updateSettings'),
  list: invoke('list'),
  read: invoke('read'),
  findAssets: invoke('findAssets'),
  saveFile: invoke('saveFile'),
  playOriginal: invoke('playOriginal'),
  openRuntimeHelp: invoke('openRuntimeHelp'),
  openLogs: invoke('openLogs'),
  report: invoke('report'),
  logError: invoke('logError'),
});
