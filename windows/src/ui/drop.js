'use strict';
// Local file paths of files dropped from Explorer.

const { webUtils } = require('electron');

function droppedPathsOf(e) {
  return [...(e.dataTransfer ? e.dataTransfer.files : [])].map(f => webUtils.getPathForFile(f)).filter(Boolean);
}

module.exports = { droppedPathsOf };
