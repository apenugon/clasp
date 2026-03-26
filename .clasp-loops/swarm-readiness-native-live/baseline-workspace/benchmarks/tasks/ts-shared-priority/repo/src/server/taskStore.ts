import { CreateTaskInput, TaskItem } from "../shared/contracts.js";

let nextTaskId = 1;
const tasks: TaskItem[] = [];

export function createTask(input: CreateTaskInput): TaskItem {
  const task: TaskItem = {
    id: String(nextTaskId),
    title: input.title.trim(),
    completed: false
  };

  nextTaskId += 1;
  tasks.push(task);
  return task;
}

export function listTasks(): TaskItem[] {
  return tasks.map((task) => ({ ...task }));
}

export function resetTasks(): void {
  nextTaskId = 1;
  tasks.length = 0;
}

