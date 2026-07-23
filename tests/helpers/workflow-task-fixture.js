'use strict';

const fs = require('fs');
const path = require('path');

function focusedTaskFile(projectRoot) {
  const pointerFile = path.join(projectRoot, '追踪', 'workflow', 'current-task.json');
  const pointer = JSON.parse(fs.readFileSync(pointerFile, 'utf8'));
  const durableFile = pointer.task_dir ? path.join(projectRoot, pointer.task_dir, 'task.json') : '';
  return durableFile && fs.existsSync(durableFile) ? durableFile : pointerFile;
}

function readFocusedTask(projectRoot) {
  return JSON.parse(fs.readFileSync(focusedTaskFile(projectRoot), 'utf8'));
}

module.exports = { focusedTaskFile, readFocusedTask };
