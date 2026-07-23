'use strict';

const { assertStorageBackend } = require('./storage-backend-contract');
const { LocalStorageBackend } = require('./local-storage-backend');

class UserProfileRepository {
  constructor(projectRoot, options = {}) {
    this.backend = assertStorageBackend(options.backend || new LocalStorageBackend(projectRoot));
  }

  preferences() {
    return this.backend.readJsonlLatest('追踪/workflow/preference-memory.jsonl', ['entryId', 'id', 'rule_id'])
      .filter(isActive)
      .map(item => ({
        id: String(item.entryId || item.id || item.rule_id || ''),
        category: String(item.category || item.type || ''),
        content: String(item.content || item.rule || item.proposedContent || ''),
        scope: String(item.scope || item.affects || ''),
      }))
      .filter(item => item.id && item.content);
  }

  summary() {
    const preferences = this.preferences();
    return {
      preference_count: preferences.length,
      interaction_preferences: preferences.filter(item => /interaction|menu|交互|菜单/u.test(`${item.category} ${item.scope} ${item.content}`)),
      routing_preferences: preferences.filter(item => /route|workflow|private|路由|私有/u.test(`${item.category} ${item.scope} ${item.content}`)),
    };
  }
}

function isActive(row) {
  return !['superseded', 'rejected', 'quarantined', 'invalid'].includes(String((row || {}).status || 'active').toLowerCase());
}

module.exports = { UserProfileRepository };
