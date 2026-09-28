import mimic/auth/storage.{type Store}
import mimic/fleet
import mimic/quota
import mimic/quota/worker
import mimic/types.{type WireResponse}

/// Fleet owns sticky slots; quota worker owns the durable cooldown ledger.
pub opaque type Controller {
  Controller(pool: fleet.Pool, quotas: worker.Worker)
}

pub fn start(
  profile: fleet.Profile,
  store: Store,
) -> Result(Controller, String) {
  use state <- try(fleet.new([profile]))
  use pool <- try(fleet.start_pool(state))
  use ledger <- try(quota.load_or_empty(store))
  use quotas <- try(worker.start(store, ledger))
  Ok(Controller(pool, quotas))
}

pub fn acquire(
  controller: Controller,
  session_id: String,
  now_ms: Int,
) -> Result(fleet.Selection, String) {
  fleet.acquire(
    controller.pool,
    worker.snapshot(controller.quotas),
    session_id,
    now_ms,
  )
}

pub fn observe(
  controller: Controller,
  selection: fleet.Selection,
  response: WireResponse,
  now_ms: Int,
) -> Result(Nil, String) {
  case
    worker.record(controller.quotas, selection.profile.id, response, now_ms)
  {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(error)
  }
}

pub fn release(controller: Controller, selection: fleet.Selection) -> Nil {
  fleet.release_slot(controller.pool, selection)
}

fn try(value: Result(a, e), next: fn(a) -> Result(b, e)) -> Result(b, e) {
  case value {
    Ok(v) -> next(v)
    Error(e) -> Error(e)
  }
}
