from comfier_agent.job_timings import JobTimings


def test_timings_to_dict_phases():
    t = JobTimings(accepted_at=0.0)
    t.inputs_end = 0.5
    t.prompt_at = 0.6
    t.execution_start = 0.7
    t.execution_end = 2.0
    t.upload_start = 2.0
    t.upload_end = 2.3
    t.input_bytes = 100
    t.output_bytes = 200
    t.set_node_counts(total=5, cached=2)
    d = t.to_dict()
    assert d["inputs_ms"] == 500
    assert d["local_queue_ms"] in (99, 100)
    assert d["execute_ms"] in (1299, 1300, 1301)
    assert d["upload_ms"] in (299, 300, 301)
    assert d["nodes_total"] == 5
    assert d["nodes_cached"] == 2
