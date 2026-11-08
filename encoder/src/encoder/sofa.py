from functools import cached_property
from pathlib import Path
from typing import overload

import numpy as np
import sofar
from typing_extensions import sentinel

NOT_SUPPLIED = sentinel("Not Supplied")

class Sofa:
    def __init__(self, path: Path):
        self.sofa = sofar.read_sofa(path, verbose=False)

    @property
    def sample_rate(self) -> int:
        return self.get(int, "Data_SamplingRate", 48000)

    @property
    def Data_IR(self) -> np.ndarray:
        return self.get(np.ndarray, "Data_IR")

    @property
    def ReceiverPosition(self) -> np.ndarray:
        return self.get(np.ndarray, "ReceiverPosition", np.array([[0, 0.09, 0], [0, -0.09, 0]]))

    @overload
    def get[T](self, T:type[T], key: str) -> T: ...
    @overload
    def get[T,D](self, T:type[T], key: str, default: D) -> T|D: ...
    def get[T,D](self, T: type[T], key: str, default: D | NOT_SUPPLIED = NOT_SUPPLIED) -> T|D:
        if default is NOT_SUPPLIED:
            return getattr(self.sofa, key)
        return getattr(self.sofa, key, default)

    @cached_property
    def SourceDirections(self) -> np.ndarray:
        """Returns normalized cartesian source positions for every measurement.
        Can handle both spherical and cartesian SourcePosition conventions."""
        
        pos = np.asarray(self.get(np.ndarray, "SourcePosition"))
        pos_type = self.get(str, "SourcePosition_Type", "spherical")
        if pos_type == "spherical":
            result = pos.copy()
            units = [x.strip() for x in self.get(str, "SourcePosition_Units", "degree, degree, metre").split(",")]
            if units[0].startswith("degree"):
                result = np.radians(result)
            az, el = result[:, 0], result[:, 1]
            return np.stack(
                (
                    np.cos(el) * np.cos(az),
                    np.cos(el) * np.sin(az),
                    np.sin(el)
                ),
                axis=-1,
            )
            
        elif pos_type == "cartesian":
            return pos / np.linalg.vector_norm(pos, axis=-1, keepdims=True)
        else:
            raise ValueError(f"Unrecognized source position format: {pos_type!r}")
