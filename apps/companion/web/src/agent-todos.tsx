import type { TranscriptBlock } from './types';

interface Todo {
  content: string;
  status: string;
  priority?: string;
}

const statuses: Record<string, { label: string; icon: string }> = {
  pending: { label: 'Pending', icon: '○' },
  in_progress: { label: 'Working', icon: '◉' },
  completed: { label: 'Completed', icon: '✓' },
  cancelled: { label: 'Cancelled', icon: '−' },
};

function parseTodos(value: unknown): Todo[] | undefined {
  if (typeof value === 'string') {
    try {
      return parseTodos(JSON.parse(value));
    } catch {
      return undefined;
    }
  }
  if (value && typeof value === 'object' && 'todos' in value) return parseTodos(value.todos);
  if (!Array.isArray(value)) return undefined;
  if (
    !value.every(
      (item) => item && typeof item.content === 'string' && Object.hasOwn(statuses, item.status),
    )
  )
    return undefined;
  return value.map((item) => ({
    content: item.content,
    status: item.status,
    priority: ['high', 'medium', 'low'].includes(item.priority) ? item.priority : undefined,
  }));
}

export function blockTodos(block: TranscriptBlock): Todo[] | undefined {
  if (block.kind === 'plan') return parseTodos(block.entries);
  if (block.kind !== 'tool' || block.status === 'failed') return undefined;
  // ACP tool titles may include a namespace or a human-readable suffix.
  if (!/(?:^|[\s.:/])todo(?:write|read)(?:$|[\s(:])/i.test(block.title || '')) return undefined;
  return (
    parseTodos(block.rawOutput) ??
    parseTodos(block.rawInput) ??
    block.content?.map((item) => parseTodos(item.content?.text ?? item.text)).find(Array.isArray)
  );
}

export function latestTodos(blocks: TranscriptBlock[]): Todo[] | undefined {
  for (let index = blocks.length - 1; index >= 0; index--) {
    const todos = blockTodos(blocks[index]);
    if (todos !== undefined) return todos;
  }
  return undefined;
}

export function TodoList({ todos }: { todos: Todo[] }) {
  return (
    <ul className="agent-todo-list">
      {todos.map((todo, index) => (
        <li className={`agent-todo agent-todo-${todo.status}`} key={index}>
          <span className="agent-todo-icon" aria-hidden="true">
            {statuses[todo.status].icon}
          </span>
          <span className="agent-todo-content">{todo.content}</span>
          <span className="agent-todo-status">{statuses[todo.status].label}</span>
          {todo.priority && (
            <span className={`agent-todo-priority priority-${todo.priority}`}>{todo.priority}</span>
          )}
        </li>
      ))}
    </ul>
  );
}

export function AgentTodos({ todos }: { todos?: Todo[] }) {
  if (todos === undefined) return null;
  const completed = todos.filter((todo) => todo.status === 'completed').length;
  const active = todos.filter((todo) => todo.status === 'in_progress');
  return (
    <details className="agent-todos" open>
      <summary>
        <strong>Agent todos</strong>
        <span role="status">
          {completed}/{todos.length} completed
        </span>
      </summary>
      {!!todos.length && (
        <progress aria-label="Todo completion" value={completed} max={todos.length} />
      )}
      {active.length > 0 && (
        <p className="agent-todo-current">
          Working on: {active.map((todo) => todo.content).join(' · ')}
        </p>
      )}
      {todos.length ? (
        <TodoList todos={todos} />
      ) : (
        <p className="agent-todo-current">No current todos.</p>
      )}
    </details>
  );
}
