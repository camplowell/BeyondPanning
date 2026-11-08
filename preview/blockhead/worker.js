const RENDER_QUANTUM_FRAMES = 128;

class BlockheadProcessor extends AudioWorkletProcessor {
    static parameterDescriptors = [
        { name: 'x', defaultValue: -1, automationRate: 'k-rate' },
        { name: 'y', defaultValue: 0, automationRate: 'k-rate' },
        { name: 'z', defaultValue: 0, automationRate: 'k-rate' },
    ];

    constructor(options) {
        super();
        const { module } = options.processorOptions;
        let wasmInstance = new WebAssembly.Instance(module);
        this.wasm = wasmInstance.exports;
        this.wasm.configureListener(sampleRate, 0.076, 0.009);
        this.src_ptr = this.wasm.initSource(1, 0, 0);
        this.in = new Float32Array(this.wasm.memory.buffer, this.wasm.inPtr(), RENDER_QUANTUM_FRAMES);
        const out_ptr = this.wasm.outPtr();
        this.out_l = new Float32Array(this.wasm.memory.buffer, out_ptr, RENDER_QUANTUM_FRAMES);
        this.out_r = new Float32Array(this.wasm.memory.buffer, out_ptr + 4 * RENDER_QUANTUM_FRAMES, RENDER_QUANTUM_FRAMES);
    }

    process(inputs, outputs, parameters) {
        const input = inputs[0][0];
        if (!input) return true;
        if (input.length != RENDER_QUANTUM_FRAMES) return false;

        this.wasm.setDirection(this.src_ptr, parameters.x[0], parameters.y[0], parameters.z[0]);
        this.in.set(input);
        
        this.wasm.process(this.src_ptr);
        
        outputs[0][0].set(this.out_l);
        outputs[0][1].set(this.out_r);
        return true;
    }
}

registerProcessor('blockhead-panner', BlockheadProcessor);
