<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <style>
        body { margin: 0; overflow: hidden; background-color: #000000; }
        canvas { width: 100vw; height: 100vh; display: block; }
        #video-container {
            position: absolute; bottom: 10px; left: 10px;
            width: 120px; height: 90px; border: 1px solid #00aaff;
            opacity: 0.2; transform: scaleX(-1); pointer-events: none; z-index: 10;
        }
        video { width: 100%; height: 100%; object-fit: cover; }
    </style>
</head>
<body>
    <div id="video-container"><video id="webcam" autoplay playsinline></video></div>

    <script src="https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/three@0.128.0/examples/js/loaders/OBJLoader.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/three@0.128.0/examples/js/controls/OrbitControls.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/three@0.128.0/examples/js/math/MeshSurfaceSampler.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/@mediapipe/hands/hands.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/@mediapipe/camera_utils/camera_utils.js"></script>

    <script>
        const scene = new THREE.Scene();
        const camera = new THREE.PerspectiveCamera(75, window.innerWidth / window.innerHeight, 1, 10000);
        const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
        renderer.setPixelRatio(window.devicePixelRatio);
        renderer.setSize(window.innerWidth, window.innerHeight);
        document.body.appendChild(renderer.domElement);

        const controls = new THREE.OrbitControls(camera, renderer.domElement);
        controls.enableDamping = true;

        let morphProgress = 0; 
        let currentMorph = 0; 

        const loader = new THREE.OBJLoader();
        const urlA = 'https://raw.githubusercontent.com/ziyangl508-ctrl/temp-toolstack-landing/main/wanzheng.obj';
        const urlB = 'https://raw.githubusercontent.com/ziyangl508-ctrl/temp-toolstack-landing/main/duan.obj';

        let particleSystem;
        let posA = [], posB = []; 
        const particleCount = 30000; 

        function processModel(object, targetArray) {
            object.scale.set(0.5, 0.5, 0.5);
            object.updateMatrixWorld(true);
            const box = new THREE.Box3().setFromObject(object);
            const center = new THREE.Vector3();
            box.getCenter(center);

            let meshes = [];
            object.traverse(child => { if (child.isMesh) meshes.push(child); });

            for (let i = 0; i < particleCount; i++) {
                const mesh = meshes[Math.floor(Math.random() * meshes.length)];
                const sampler = new THREE.MeshSurfaceSampler(mesh).build();
                const v = new THREE.Vector3();
                sampler.sample(v);
                v.applyMatrix4(mesh.matrixWorld);
                targetArray.push(v.x - center.x, v.y - center.y, v.z - center.z);
            }
        }

        loader.load(urlA, (objA) => {
            processModel(objA, posA);
            loader.load(urlB, (objB) => {
                processModel(objB, posB);
                initParticles();
            });
        });

        function initParticles() {
            const geometry = new THREE.BufferGeometry();
            geometry.setAttribute('position', new THREE.Float32BufferAttribute(posA, 3));
            
            const material = new THREE.PointsMaterial({
                color: 0x00ccff, 
                size: 2.0,
                transparent: true, 
                opacity: 0.9,
                blending: THREE.AdditiveBlending,
                depthWrite: false
            });

            particleSystem = new THREE.Points(geometry, material);
            scene.add(particleSystem);
            camera.position.set(0, 0, 800); 
            controls.target.set(0, 0, 0);
        }

        const videoElement = document.getElementById('webcam');
        const hands = new Hands({ locateFile: (f) => `https://cdn.jsdelivr.net/npm/@mediapipe/hands/${f}` });
        hands.setOptions({ maxNumHands: 1, modelComplexity: 1, minDetectionConfidence: 0.5 });
        
        hands.onResults((res) => {
            if (res.multiHandLandmarks && res.multiHandLandmarks.length > 0) {
                const l = res.multiHandLandmarks[0];
                const dist = Math.sqrt(Math.pow(l[4].x-l[8].x,2)+Math.pow(l[4].y-l[8].y,2));
                // 优化映射区间，让握拳更易触发 0
                let rawProgress = (dist - 0.08) / 0.22;
                morphProgress = Math.max(0, Math.min(1, rawProgress)); 
            } else { 
                // 手不在画面时强制回归模型A
                morphProgress = 0; 
            }
        });
        
        new Camera(videoElement, { onFrame: async () => { await hands.send({image: videoElement}); }, width: 640, height: 480 }).start();

        function animate() {
            requestAnimationFrame(animate);
            if (particleSystem && posA.length >= particleCount * 3 && posB.length >= particleCount * 3) {
                // 调高系数（0.15）让响应更敏捷，防止卡死
                currentMorph += (morphProgress - currentMorph) * 0.15;
                
                const positions = particleSystem.geometry.attributes.position.array;
                const time = Date.now() * 0.002;

                particleSystem.material.size = 2.2 * (1 - currentMorph) + 1.2 * currentMorph;
                particleSystem.material.opacity = 0.9 * (1 - currentMorph) + 0.6 * currentMorph;

                for (let i = 0; i < positions.length; i += 3) {
                    const idx = i;
                    const targetX = posA[idx] * (1 - currentMorph) + posB[idx] * currentMorph;
                    const targetY = posA[idx+1] * (1 - currentMorph) + posB[idx+1] * currentMorph;
                    const targetZ = posA[idx+2] * (1 - currentMorph) + posB[idx+2] * currentMorph;

                    const shake = 0.4 * currentMorph; 
                    positions[idx] = targetX + Math.sin(time + i) * shake;
                    positions[idx+1] = targetY + Math.cos(time + i * 1.1) * shake;
                    positions[idx+2] = targetZ + Math.sin(time + i * 1.2) * shake;
                }
                particleSystem.geometry.attributes.position.needsUpdate = true;
            }
            controls.update();
            renderer.render(scene, camera);
        }

        animate();
        window.addEventListener('resize', () => {
            camera.aspect = window.innerWidth / window.innerHeight;
            camera.updateProjectionMatrix();
            renderer.setSize(window.innerWidth, window.innerHeight);
        });
    </script>
</body>
</html>
