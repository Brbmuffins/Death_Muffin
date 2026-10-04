import { describeSave, type Choice, type Done } from './accountSync';

/** The compare-and-choose card shared by the login screen and the offline panel. Nothing is replaced until a button is pressed. */
export function mountChooser(host: HTMLElement, choice: Choice, onDone: (d: Done) => void, onError: (message: string) => void, confirmFn: (m: string) => boolean = (m) => window.confirm(m)) {
  host.hidden = false;
  host.replaceChildren();
  const intro = document.createElement('p');
  intro.dataset.chooserIntro = '';
  intro.textContent = `Your online character "${choice.account}" and the save on this device are different. Choose which one to keep playing. The other is kept: the server keeps replaced online saves as versions you can restore, and a replaced device save stays as a local player.`;
  const online = document.createElement('p');
  online.textContent = `Online: ${describeSave(choice.online)}.`;
  const local = document.createElement('p');
  local.textContent = choice.local ? `This device: ${describeSave(choice.local)}.` : 'This device: no character yet.';
  const useOnline = document.createElement('button');
  useOnline.type = 'button';
  useOnline.className = 'cw-button primary';
  useOnline.dataset.chooseOnline = '';
  useOnline.textContent = 'Use my online save here';
  const useLocal = document.createElement('button');
  useLocal.type = 'button';
  useLocal.className = 'cw-button';
  useLocal.dataset.chooseLocal = '';
  useLocal.textContent = 'Use this device\'s save online';
  useLocal.disabled = !choice.canPush;
  host.append(intro, online, local);
  if (!choice.canPush && choice.pushBlockedReason) {
    const why = document.createElement('p');
    why.textContent = choice.pushBlockedReason;
    host.append(why);
  }
  host.append(useOnline, useLocal);

  const run = async (button: HTMLButtonElement, fn: () => Promise<Done>) => {
    useOnline.disabled = true; useLocal.disabled = true;
    try { onDone(await fn()); }
    catch (e) {
      onError(e instanceof Error ? e.message : 'Could not finish the sync.');
      useOnline.disabled = false; useLocal.disabled = !choice.canPush;
    }
    void button;
  };
  useOnline.addEventListener('click', () => void run(useOnline, () => choice.useOnline()));
  useLocal.addEventListener('click', () => {
    if (!confirmFn('Replace your ONLINE character with the save on this device? The current online save is kept as a version you can restore.')) return;
    void run(useLocal, () => choice.useLocal());
  });
}
