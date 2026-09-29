// Gives the page one narrow channel to the main process: a structured log record.
'use strict';
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('dropyFixture', {
  log: (record) => ipcRenderer.send('fixture-log', record),
});
