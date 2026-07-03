import * as THREE from 'three';

/**
 * Shared WebGL renderer + resize handling.
 * threejs-aaa-graphics-builder territory once this grows: lighting rigs,
 * postprocessing, material library, env probes all hang off this renderer.
 */
export function createRenderer(canvas: HTMLCanvasElement) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  renderer.setSize(window.innerWidth, window.innerHeight);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;
  return renderer;
}

export function fitToWindow(renderer: THREE.WebGLRenderer, camera: THREE.PerspectiveCamera) {
  const resize = () => {
    const w = window.innerWidth;
    const h = window.innerHeight;
    renderer.setSize(w, h);
    camera.aspect = w / h;
    camera.updateProjectionMatrix();
  };
  window.addEventListener('resize', resize);
  resize();
}
