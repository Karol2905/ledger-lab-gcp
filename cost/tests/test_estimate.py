import json
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE.parent))

import estimate as cost  # noqa: E402

PRICES = {
    "run_vcpu_second": 0.000024,
    "run_gib_second": 0.0000025,
    "run_million_requests": 0.4,
    "sql_micro_hour": 0.01,
    "sql_ssd_gib_month": 0.17,
    "sql_backup_gib_month": 0.08,
    "secret_version_month": 0.06,
    "secret_10k_access": 0.03,
    "log_gib": 0.5,
    "gcs_gib_month": 0.02,
    "gcs_10k_writes": 0.05,
}


def book():
    return cost.PriceBook({"us-central1": PRICES}, offline=True)


def usage(**overrides):
    base = json.loads((HERE.parent / "usage.json").read_text())
    base.update(overrides)
    return base


def app(cpu="1", memory="512Mi"):
    return {
        "address": "module.stack.module.app.google_cloud_run_v2_service.this",
        "mode": "managed",
        "type": "google_cloud_run_v2_service",
        "values": {"location": "us-central1", "template": [
            {"containers": [{"resources": [{"limits": {"cpu": cpu, "memory": memory}}]}]}
        ]},
    }


def database(tier="db-f1-micro", backups=False):
    return {
        "address": "module.stack.module.database.google_sql_database_instance.this",
        "mode": "managed",
        "type": "google_sql_database_instance",
        "values": {"region": "us-central1", "settings": [{
            "tier": tier, "disk_size": 10, "backup_configuration": [{"enabled": backups}],
        }]},
    }


def secret(name="jwt-secret"):
    return {
        "address": f'module.stack.module.secrets.google_secret_manager_secret_version.this["{name}"]',
        "mode": "managed", "type": "google_secret_manager_secret_version", "values": {},
    }


def plan(*resources):
    return {"planned_values": {"root_module": {"child_modules": [{"resources": list(resources)}]}}}


def total(lines):
    return sum(line.monthly_usd for line in lines)


def test_free_tier_covers_light_usage():
    lines, unknown = cost.estimate({"dev": plan(app())}, usage(), book())
    assert total(lines) == 0
    assert unknown == []


def test_usage_over_free_tier_is_billed():
    lines, _ = cost.estimate(
        {"dev": plan(app())}, usage(app_active_hours_per_month={"dev": 100}), book()
    )
    # 360k segundos x 1 vCPU - 180k gratis = 180k; x 0.5 GiB = 180k, dentro de los 360k gratis.
    assert total(lines) == pytest.approx(180_000 * 0.000024)


def test_free_tier_is_shared_between_environments():
    hours = {"dev": 40, "prod": 40}
    alone, _ = cost.estimate(
        {"dev": plan(app())}, usage(app_active_hours_per_month=hours), book()
    )
    both, _ = cost.estimate(
        {"dev": plan(app()), "prod": plan(app())},
        usage(app_active_hours_per_month=hours), book(),
    )
    assert total(alone) == 0
    assert total(both) > 0


def test_cloud_sql_bills_every_hour_it_exists():
    lines, _ = cost.estimate(
        {"dev": plan(database())}, usage(sql_hours_per_month={"dev": 730}), book()
    )
    assert total(lines) == pytest.approx(730 * 0.01 + 10 * 0.17)


def test_backups_are_billed_only_when_enabled():
    hours = {"dev": 730}
    without, _ = cost.estimate({"dev": plan(database())}, usage(sql_hours_per_month=hours), book())
    with_backups, _ = cost.estimate(
        {"dev": plan(database(backups=True))}, usage(sql_hours_per_month=hours), book()
    )
    assert total(with_backups) - total(without) == pytest.approx(1 * 0.08)


def test_bigger_tier_without_rule_is_an_error():
    with pytest.raises(cost.PriceNotFound):
        cost.estimate({"dev": plan(database(tier="db-custom-4-16384"))}, usage(), book())


def test_secret_versions_beyond_free_tier_are_billed():
    secrets = [secret(f"s{i}") for i in range(8)]
    lines, _ = cost.estimate({"dev": plan(*secrets)}, usage(), book())
    assert total(lines) == pytest.approx(2 * 0.06, rel=0.01)


def test_unknown_resource_is_reported():
    vm = {"address": "google_compute_instance.x", "mode": "managed",
          "type": "google_compute_instance", "values": {}}
    _, unknown = cost.estimate({"dev": plan(vm)}, usage(), book())
    assert unknown == ["dev: google_compute_instance.x"]


def test_data_sources_and_helpers_are_ignored():
    data = {"address": "data.x", "mode": "data", "type": "google_project", "values": {}}
    helper = {"address": "random_string.s", "mode": "managed", "type": "random_string", "values": {}}
    lines, unknown = cost.estimate({"dev": plan(data, helper)}, usage(), book())
    assert lines == [] and unknown == []


def test_without_token_falls_back_to_snapshot(monkeypatch):
    monkeypatch.delenv("GOOGLE_OAUTH_ACCESS_TOKEN", raising=False)
    prices = cost.PriceBook({"us-central1": PRICES})
    assert prices.price("sql_micro_hour", "us-central1") == 0.01
    assert prices.used_snapshot


def test_missing_price_is_an_error_not_zero():
    with pytest.raises(cost.PriceNotFound):
        cost.PriceBook({}, offline=True).price("sql_micro_hour", "us-central1")


def run_cli(tmp_path, resources, *extra):
    path = tmp_path / "plan.json"
    path.write_text(json.dumps(plan(*resources)))
    snapshot = tmp_path / "prices.json"
    snapshot.write_text(json.dumps({"us-central1": PRICES}))
    return cost.main([
        "--plan", f"dev={path}", "--snapshot", str(snapshot), "--offline", *extra,
    ])


def test_budget_gate_fails_when_exceeded(tmp_path):
    assert run_cli(tmp_path, [database()], "--budget", "0.1") == 1


def test_budget_gate_passes_within_limit(tmp_path):
    assert run_cli(tmp_path, [database()], "--budget", "1") == 0


def test_unknown_resource_fails_the_gate(tmp_path):
    vm = {"address": "google_compute_instance.x", "mode": "managed",
          "type": "google_compute_instance", "values": {}}
    assert run_cli(tmp_path, [vm]) == 1
