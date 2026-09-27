"""
SMAC benchmark worker for PyExperimenter.

This module defines the function that PyExperimenter calls for each row
in the experiment grid. Each row represents one (algorithm, dataset, seed)
triple. The worker runs a SMAC optimization and writes the result back.

Replace src/hello.py with this file, and update the Dockerfile CMD to:
    CMD ["python", "src/smac_worker.py"]

TODO for participants:
  - [ ] Add real benchmark datasets (currently uses a synthetic function)
  - [ ] Extend the ConfigSpace per algorithm variant
  - [ ] Add walltime / memory tracking to result_processor
  - [ ] Handle SMAC crashes gracefully (return NaN, set status to error)
"""

import logging
import time

import numpy as np
from ConfigSpace import ConfigurationSpace, Configuration
from smac import HyperparameterOptimizationFacade, Scenario
from py_experimenter.experimenter import PyExperimenter
from py_experimenter.result_processor import ResultProcessor

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


# ── Benchmark target functions ──────────────────────────────────────
# Each function simulates evaluating an ML algorithm configuration.
# Participants: replace these with real sklearn/pytorch benchmarks.

def synthetic_branin(config: Configuration, seed: int = 0) -> float:
    """Branin-Hoo function — a standard 2D optimization benchmark."""
    x1 = config["x1"]
    x2 = config["x2"]
    a, b, c = 1, 5.1 / (4 * np.pi**2), 5 / np.pi
    r, s, t = 6, 10, 1 / (8 * np.pi)
    return float(a * (x2 - b * x1**2 + c * x1 - r) ** 2 + s * (1 - t) * np.cos(x1) + s)


# TODO: add more target functions, e.g.:
# def svm_on_dataset(config: Configuration, seed: int = 0) -> float:
#     from sklearn.svm import SVC
#     from sklearn.datasets import load_iris
#     from sklearn.model_selection import cross_val_score
#     clf = SVC(C=config["C"], gamma=config["gamma"], random_state=seed)
#     return 1 - np.mean(cross_val_score(clf, X, y, cv=5))

BENCHMARKS = {
    "branin": {
        "target": synthetic_branin,
        "configspace": ConfigurationSpace(
            space={"x1": (-5.0, 10.0), "x2": (0.0, 15.0)}
        ),
    },
    # TODO: add entries for real benchmarks
    # "svm_iris": {
    #     "target": svm_on_dataset,
    #     "configspace": ConfigurationSpace(
    #         space={"C": (1e-3, 1e3), "gamma": (1e-5, 1e1)}
    #     ),
    # },
}


# ── PyExperimenter worker function ──────────────────────────────────
# This is what PyExperimenter calls for each unclaimed row.

def run_experiment(
    keyfields: dict,
    result_processor: ResultProcessor,
    custom_config: dict,
) -> None:
    """
    Execute one SMAC optimization run.

    Parameters
    ----------
    keyfields : dict
        Row from the experiment grid, e.g.:
        {"algorithm": "branin", "dataset": "synthetic", "seed": 42, "n_trials": 50}
    result_processor : ResultProcessor
        Callback to write results back to the database.
    custom_config : dict
        Extra settings from the PyExperimenter config YAML.
    """
    algorithm = keyfields["algorithm"]
    seed = int(keyfields["seed"])
    n_trials = int(keyfields.get("n_trials", 50))

    logger.info(
        "Starting: algorithm=%s seed=%d n_trials=%d",
        algorithm, seed, n_trials,
    )

    if algorithm not in BENCHMARKS:
        raise ValueError(
            f"Unknown algorithm '{algorithm}'. "
            f"Available: {list(BENCHMARKS.keys())}"
        )

    bench = BENCHMARKS[algorithm]
    scenario = Scenario(
        configspace=bench["configspace"],
        deterministic=False,
        n_trials=n_trials,
        seed=seed,
    )

    smac = HyperparameterOptimizationFacade(
        scenario=scenario,
        target_function=bench["target"],
    )

    start = time.time()
    incumbent = smac.optimize()
    elapsed = time.time() - start

    # Evaluate incumbent to get the final score
    cost = bench["target"](incumbent, seed=seed)

    logger.info(
        "Finished: algorithm=%s seed=%d cost=%.6f elapsed=%.1fs",
        algorithm, seed, cost, elapsed,
    )

    # Write results back to PyExperimenter database
    result_processor.process_results({
        "incumbent_cost": cost,
        "elapsed_seconds": elapsed,
        "incumbent_config": str(dict(incumbent)),
        # TODO: add more result columns as needed
        # "memory_peak_mb": ...,
        # "n_evaluations": ...,
    })


# ── Standalone entry point ──────────────────────────────────────────
# When the container starts, connect to the database and process rows
# until none are left.

def main() -> None:
    experimenter = PyExperimenter(
        experiment_configuration_file_path="config/experiment_config.yaml",
        name="smac_worker",
        use_codecarbon=False,
    )

    # Create the table if it doesn't exist, then fill from config grid
    experimenter.fill_table_from_config()

    # Process all unclaimed rows, then exit
    experimenter.execute(run_experiment)


if __name__ == "__main__":
    main()