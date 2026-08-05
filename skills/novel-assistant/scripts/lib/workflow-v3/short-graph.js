'use strict';

// Task 4 subtask A: the canonical short lifecycle graph and the only
// transition validator. This module is pure data + a pure function: it never
// touches the durable task.json. The V3 engine invokes nextNode inside its
// existing commitTask mutation so a stage transition lands in the SAME single
// state-version commit as the StageResult that triggered it. CLI and startup
// wrappers must never write current_stage themselves — they go through the
// engine, and the engine goes through this validator.

// SHORT_GRAPH is the single source of truth for which stage a short workflow
// may be in, the author-facing phase label for that stage, and the ordered set
// of stages a completed result may legally move to. A node with exactly one
// `next` target advances automatically on `completed`; a node with two or more
// targets requires the result to name its target via `next_stage`. The terminal
// node (final_check) has an empty `next` list.
const SHORT_GRAPH = Object.freeze({
  creative_entry: Object.freeze({ author_phase: '创作入口', next: Object.freeze(['material_positioning']) }),
  material_positioning: Object.freeze({ author_phase: '素材与定位', next: Object.freeze(['setting']) }),
  setting: Object.freeze({ author_phase: '规划作品', next: Object.freeze(['section_outline']) }),
  section_outline: Object.freeze({ author_phase: '规划作品', next: Object.freeze(['planning_confirmation']) }),
  planning_confirmation: Object.freeze({ author_phase: '确认方案', next: Object.freeze(['section_brief']) }),
  section_brief: Object.freeze({ author_phase: '写当前小节', next: Object.freeze(['section_draft']) }),
  section_draft: Object.freeze({ author_phase: '写当前小节', next: Object.freeze(['machine_gate']) }),
  machine_gate: Object.freeze({ author_phase: '写当前小节', next: Object.freeze(['story_gate', 'section_repair']) }),
  section_repair: Object.freeze({ author_phase: '修改当前小节', next: Object.freeze(['machine_gate']) }),
  story_gate: Object.freeze({ author_phase: '写当前小节', next: Object.freeze(['section_accept', 'section_repair']) }),
  section_accept: Object.freeze({ author_phase: '采用当前小节', next: Object.freeze(['section_brief', 'assembly', 'machine_gate']) }),
  assembly: Object.freeze({ author_phase: '全篇收束', next: Object.freeze(['editorial_review', 'machine_gate']) }),
  editorial_review: Object.freeze({ author_phase: '全篇收束', next: Object.freeze(['deslop', 'planning_confirmation', 'machine_gate']) }),
  deslop: Object.freeze({ author_phase: '表达精修', next: Object.freeze(['final_check']) }),
  final_check: Object.freeze({ author_phase: '终检', next: Object.freeze([]) }),
});

// The canonical short entry stage. The Engine owns this value: createTask
// stamps it onto the durable task, and callers are rejected if they try to set
// current_stage themselves. Exported so the Engine (and only the Engine) reads
// the single source of truth for where a short lifecycle begins.
const SHORT_ENTRY_STAGE = 'creative_entry';

// The ONLY transition validator. Returns the stage id the task should sit on
// after `result` is applied to `task`; it never mutates either argument.
//
//   - retryable_internal / needs_author_choice / blocked: stay on the current
//     node regardless of its next list. The host is still working the same
//     stage, so the graph must not move.
//   - completed on a one-target node: advance automatically. No next_stage is
//     required (and none is consulted) because there is no choice to make.
//   - completed on a multi-target node: the result must name its target via
//     next_stage, and that target must be a member of the current node's next
//     list. A missing or empty next_stage is rejected as next_stage_required;
//     a target outside the list is rejected as next_stage_outside_node.
//   - completed on the terminal node (final_check, next: []): a completed
//     result is LEGAL and the node stays current. The Engine uses this signal
//     (isTerminalCompletion) to mark the task and lifecycle completed in the
//     same single commit. A non-completed result at the terminal node also
//     stays put and does NOT complete.
//
// The engine applies the returned stage inside its own commitTask mutation; a
// thrown error propagates out before any write is attempted, so a rejected
// transition never lands in the durable task.json.
function nextNode(task, result) {
  const current = String((task || {}).current_stage || '');
  const node = SHORT_GRAPH[current];
  if (!node) throw new Error('unknown_current_stage');

  const kind = String((result || {}).kind || '');
  if (kind !== 'completed') return current;

  // Terminal node: completed is legal but there is nowhere to advance. The
  // engine owns the completion side-effect; nextNode just keeps the node.
  if (node.next.length === 0) return current;

  if (node.next.length === 1) return node.next[0];

  const target = String((result || {}).next_stage || '').trim();
  if (!target) throw new Error('next_stage_required');
  if (!node.next.includes(target)) throw new Error('next_stage_outside_node');
  return target;
}

// The Engine's completion signal: a completed result applied while sitting on a
// terminal node (no outgoing edges) closes the lifecycle. Only a completed
// result triggers this; retryable_internal / needs_author_choice / blocked at
// the terminal node do not. The engine calls this inside its commitTask mutator
// so completion lands in the SAME single state-version commit as the result.
function isTerminalCompletion(task, result) {
  const current = String((task || {}).current_stage || '');
  const node = SHORT_GRAPH[current];
  if (!node) return false;
  if (node.next.length !== 0) return false;
  return String((result || {}).kind || '') === 'completed';
}

module.exports = {
  SHORT_GRAPH,
  SHORT_ENTRY_STAGE,
  nextNode,
  isTerminalCompletion,
};
