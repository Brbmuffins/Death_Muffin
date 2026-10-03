/** "Death Muffin was updated" bar: a countdown and a Reload now button. */
export class UpdateNotice {
  private el: HTMLDivElement;
  private msg: HTMLSpanElement;

  constructor(onReload: () => void) {
    this.el = document.createElement('div');
    this.el.className = 'dm-update';
    this.el.setAttribute('role', 'status');
    this.el.setAttribute('aria-live', 'polite');
    this.msg = document.createElement('span');
    this.msg.className = 'dm-update-msg';
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.textContent = 'Reload now';
    btn.addEventListener('click', onReload);
    this.el.append(this.msg, btn);
    document.body.appendChild(this.el);
  }

  text(t: string) {
    this.msg.textContent = t;
  }

  dispose() {
    this.el.remove();
  }
}
