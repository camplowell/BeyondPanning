
from typing import NamedTuple, cast

import jax
import numpy as np
import optax
from jax import numpy as jnp
from scipy.constants import speed_of_sound
from scipy.signal import butter, resample_poly, sosfiltfilt

from encoder.sofa import Sofa


def fit(sofa: Sofa) -> Blockhead:
    input = Input.load(sofa)
    target = getTarget(sofa)

    model = Blockhead(jnp.array([0.083]), jnp.array([0.03]))
    optimizer = optax.amsgrad(1e-2)
    opt_state = optimizer.init(model)
    print("Fitting geometric model...")
    for _ in range(192):
        loss, grads = loss_and_grad(model, input, target)
        print(f"\x1b[2K Loss: {loss:.6f}", end='\r')
        updates, opt_state = optimizer.update(grads, opt_state)
        model = cast(Blockhead, optax.apply_updates(model, updates))
    print("\n")
    return model

@jax.jit
@jax.value_and_grad
def loss_and_grad(model: Blockhead, x: tuple[Input, Input], y: jax.Array):
    return jnp.mean(optax.l2_loss(blockheadDelay(model, x[0]) - blockheadDelay(model, x[1]), y))
    

    

def getTarget(sofa: Sofa) -> jax.Array:
    hp = sosfiltfilt(
        butter(2, 2000.0, fs=sofa.sample_rate, btype="highpass", output="sos"),
        sofa.Data_IR,
        axis=-1
    )
    hp = resample_poly(hp, up=16, down=1, axis=-1)
    fs_hp = sofa.sample_rate * 16

    peaks = np.max(hp, axis=-1, keepdims=True)
    onsets = np.divide(
        np.argmax(hp > peaks * 0.316227766, axis=-1), # -10db
        fs_hp,
        dtype=np.float64,
    )

    return jnp.array((onsets[:, 0] - onsets[:, 1]) * speed_of_sound)

class Input(NamedTuple):
    angle_ipsilateral: jax.Array
    angle_vertical: jax.Array

    def load(sofa: Sofa) -> tuple[Input, Input]:
        directions = sofa.SourceDirections
        angle_vertical = jnp.atan2(directions[:, 2], directions[:, 0])
        return (
            Input(
                angle_ipsilateral=jnp.acos(directions[:, 1]),
                angle_vertical=angle_vertical,
            ),
            Input(
                angle_ipsilateral=jnp.acos(-directions[:, 1]),
                angle_vertical=angle_vertical,
            )
        )

    def flip(self) -> Input:
        return Input(
            angle_ipsilateral = jnp.pi - self.angle_ipsilateral,
            angle_vertical = self.angle_vertical
        )

class Blockhead(NamedTuple):
    radius: jax.Array
    block: jax.Array

def blockheadDelay(head: Blockhead, input: Input) -> jax.Array:

    def ipsilateral() -> jax.Array:
        return head.radius * (1 - jnp.cos(input.angle_ipsilateral))

    def contralateral() -> jax.Array:
        angle_contralateral = input.angle_ipsilateral - jnp.pi / 2
        
        t = jnp.clip(1 - abs(input.angle_vertical - jnp.radians(110)) / jnp.radians(50), 0, 1)
        growth = head.radius * 0.15 * (3 * pow(t, 2) - 2 * pow(t, 3))
        a_prime = head.radius + growth
        b_prime = jnp.sqrt(pow(head.block, 2) + pow(growth, 2))
        
        return (
            head.radius
            + a_prime * angle_contralateral
            + b_prime
            - head.block * jnp.cos(angle_contralateral)
        )

    return head.radius + jnp.where(
        input.angle_ipsilateral < (jnp.pi / 2),
        ipsilateral(),
        contralateral()
    )
