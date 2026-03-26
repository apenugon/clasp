import type { TaskItem } from "../shared/contracts.js";

export function renderTask(task: TaskItem): string {
  return `<li data-task-id="${task.id}">${task.title}</li>`;
}

export function renderTaskList(tasks: TaskItem[]): string {
  return `<ul>${tasks.map(renderTask).join("")}</ul>`;
}

