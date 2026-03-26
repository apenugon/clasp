import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";
import { renderTaskList } from "../dist/client/render.js";
import { createTask, listTasks, resetTasks } from "../dist/server/taskStore.js";

beforeEach(() => {
  resetTasks();
});

test("createTask stores an explicit priority and renderTaskList displays it", () => {
  const task = createTask({
    title: "Ship benchmark story",
    priority: "high"
  });

  assert.equal(task.priority, "high");
  assert.equal(listTasks()[0].priority, "high");

  const html = renderTaskList(listTasks());
  assert.match(html, /priority-high/);
  assert.match(html, /High priority/);
});

test("createTask defaults missing priority to medium", () => {
  const task = createTask({
    title: "Write roadmap update"
  });

  assert.equal(task.priority, "medium");
});

