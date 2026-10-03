// Direction B ("Away"): the sticky phone follows the story, and the
// illustrative approval and question cards respond to taps. The page is
// complete without this script.

const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

function initPhone() {
  const phone = document.querySelector<HTMLElement>('[data-phone]');
  const clock = document.querySelector<HTMLElement>('[data-phone-clock]');
  const bands = [...document.querySelectorAll<HTMLElement>('[data-day] .band[data-scene]')];
  if (!phone || !bands.length || !('IntersectionObserver' in window)) return;

  const screens = [...phone.querySelectorAll<HTMLElement>('.phone__screen')];
  const strip = [...document.querySelectorAll<HTMLElement>('[data-strip]')];

  const show = (scene: string, time: string) => {
    phone.dataset.scene = scene;
    if (clock) clock.textContent = time;
    for (const screen of screens) {
      const active = screen.dataset.for === scene;
      screen.inert = !active;
      screen.setAttribute('aria-hidden', String(!active));
    }
    for (const link of strip) {
      const active = link.dataset.strip === scene;
      link.classList.toggle('is-active', active);
      if (active) link.setAttribute('aria-current', 'true');
      else link.removeAttribute('aria-current');
    }
  };

  show(bands[0].dataset.scene ?? 'live', bands[0].dataset.time ?? '');

  // A band is "now" while it covers the middle of the viewport.
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const band = entry.target as HTMLElement;
        show(band.dataset.scene ?? 'live', band.dataset.time ?? '');
      }
    },
    { rootMargin: '-50% 0px -50% 0px' },
  );
  for (const band of bands) observer.observe(band);
}

function initClocks() {
  if (reducedMotion || !('IntersectionObserver' in window)) return;
  // Only clocks that start below the fold animate in, so nothing visible blinks.
  const pending = [...document.querySelectorAll<HTMLElement>('[data-clock]')].filter(
    (clock) => clock.getBoundingClientRect().top > window.innerHeight,
  );
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add('clock-in');
        observer.unobserve(entry.target);
      }
    },
    { threshold: 0.5 },
  );
  for (const clock of pending) {
    clock.classList.add('clock-pending');
    observer.observe(clock);
  }
}

const streams = new WeakMap<HTMLElement, number>();

function type(target: HTMLElement, text: string) {
  window.clearInterval(streams.get(target));
  if (reducedMotion) {
    target.textContent = text;
    return;
  }
  let shown = 0;
  target.textContent = '';
  const timer = window.setInterval(() => {
    shown += 2;
    target.textContent = text.slice(0, shown);
    if (shown >= text.length) window.clearInterval(timer);
  }, 28);
  streams.set(target, timer);
}

function replyText(stream: HTMLElement, answer: string | undefined) {
  const template = stream.dataset.template;
  if (template && answer) return template.replace('{answer}', answer);
  stream.dataset.full ??= stream.textContent ?? '';
  return stream.dataset.full;
}

function initDemos() {
  document.addEventListener('click', (event) => {
    const button = (event.target as HTMLElement).closest<HTMLElement>('[data-action]');
    const used = button?.closest<HTMLElement>('[data-screen]');
    if (!button || !used) return;

    const state = button.dataset.action ?? 'ask';
    const answer = button.dataset.answer;

    // The phone and the inline card show the same moment; keep them in step.
    for (const screen of document.querySelectorAll<HTMLElement>(`[data-screen="${used.dataset.screen}"]`)) {
      screen.dataset.state = state;
      const outcome = screen.querySelector<HTMLElement>(`[data-when="${state}"]`);
      if (!outcome) continue;
      if (answer) {
        for (const slot of outcome.querySelectorAll<HTMLElement>('[data-answer-slot]')) slot.textContent = answer;
      }
      const stream = outcome.querySelector<HTMLElement>('[data-stream]');
      if (!stream) continue;
      const text = replyText(stream, answer);
      if (screen === used) type(stream, text);
      else stream.textContent = text;
    }

    const outcome = used.querySelector<HTMLElement>(`[data-when="${state}"]`);
    const focusTarget =
      state === 'ask'
        ? outcome?.querySelector<HTMLElement>('button')
        : outcome?.querySelector<HTMLElement>('[data-status]');
    focusTarget?.focus({ preventScroll: true });

    const live = used.querySelector<HTMLElement>('[data-live]');
    if (live && outcome && state !== 'ask') {
      const status = outcome.querySelector<HTMLElement>('[data-status]')?.textContent ?? '';
      const stream = outcome.querySelector<HTMLElement>('[data-stream]');
      live.textContent = `${status}. ${stream ? replyText(stream, answer) : ''}`.trim();
    }
  });
}

initPhone();
initClocks();
initDemos();

export {};
