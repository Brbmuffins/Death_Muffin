export type SceneName = 'login' | 'characterSelect' | 'hub' | 'arena' | 'boss';

export interface GameScene {
  mount(): void;
  unmount(): void;
}

/**
 * Thin scene router. Mirrors the Unity scene order:
 * LoginScene(0) -> CharacterSelect(1) -> Hub(2) -> Portal/Arena.
 */
export class SceneManager {
  private current: GameScene | null = null;

  goto(scene: GameScene) {
    this.current?.unmount();
    this.current = scene;
    scene.mount();
  }
}
