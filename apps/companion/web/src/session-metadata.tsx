import type { Session, SessionChoices } from './types';

function choiceName(options?: SessionChoices) {
  return options?.choices.find((choice) => choice.id === options.current)?.name || options?.current;
}

function count(value?: number) {
  return value === undefined ? 'Not reported' : value.toLocaleString('en-US');
}

export function SessionMetadata({ session }: { session: Session }) {
  const working = session.status === 'busy' || session.status === 'starting';
  const { tokens, context, cost } = session.usage || {};
  const percentage = context && context.size > 0 ? (context.used / context.size) * 100 : undefined;
  const details = [
    ['Input', tokens?.inputTokens],
    ['Output', tokens?.outputTokens],
    ['Thinking', tokens?.thoughtTokens],
    ['Cache read', tokens?.cachedReadTokens],
    ['Cache write', tokens?.cachedWriteTokens],
  ] as const;

  return (
    <section
      aria-label="Session metadata"
      className="mb-5 rounded-xl border border-slate-700 bg-slate-900/60 p-4"
    >
      <dl className="grid grid-cols-2 gap-4 text-sm sm:grid-cols-3">
        {[
          ['Status', session.status],
          ['Agent', session.agent],
          ['Model', choiceName(session.models) || 'Not reported'],
          ['Mode', choiceName(session.modes) || 'Not reported'],
          ['Tokens (reported turns)', count(tokens?.totalTokens)],
          [
            'Cost (last reported)',
            cost
              ? `${cost.currency} ${cost.amount.toLocaleString('en-US', { maximumFractionDigits: 8 })}`
              : 'Not reported',
          ],
        ].map(([label, value]) => (
          <div key={label} className="min-w-0">
            <dt className="text-xs text-slate-400">{label}</dt>
            <dd className="mt-1 break-words font-medium">
              {label === 'Status' ? (
                <span role="status" className="inline-flex items-center gap-2">
                  {working && (
                    <span
                      aria-hidden="true"
                      className="h-3.5 w-3.5 shrink-0 rounded-full border-2 border-sky-400/30 border-t-sky-400 motion-safe:animate-spin"
                    />
                  )}
                  {session.status === 'busy'
                    ? 'Working…'
                    : session.status === 'starting'
                      ? 'Starting…'
                      : session.status === 'waiting'
                        ? 'Waiting for permission'
                        : value}
                </span>
              ) : (
                value
              )}
            </dd>
          </div>
        ))}
      </dl>
      <div className="mt-4 text-sm">
        <p className="flex flex-wrap justify-between gap-2">
          <span className="text-slate-400">Context usage</span>
          <span>
            {context
              ? `${count(context.used)} / ${count(context.size)} tokens${percentage === undefined ? '' : ` (${percentage.toFixed(1)}%)`}`
              : 'Not reported'}
          </span>
        </p>
        {percentage !== undefined && (
          <progress
            aria-label="Context window usage"
            className="mt-2 h-2 w-full accent-sky-400"
            max={100}
            value={Math.min(100, percentage)}
          />
        )}
      </div>
      {tokens && (
        <p className="mt-3 text-xs text-slate-400">
          {[
            ...(tokens.responses === undefined
              ? []
              : [`Reported turns: ${count(tokens.responses)}`]),
            ...details
              .filter(([, value]) => value !== undefined)
              .map(([label, value]) => `${label}: ${count(value)}`),
          ].join(' · ')}
        </p>
      )}
    </section>
  );
}
