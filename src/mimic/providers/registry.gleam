import gleam/list
import gleam/option.{None}
import gleam/result
import mimic/providers/contracts.{
  type Capability, type Failure, type Request, Buffer, Buffered, Continuation,
  Failure, InvalidConfiguration, NotSent, Stream, Streaming, Unsupported,
}

pub type Model {
  Model(
    provider: String,
    id: String,
    auth_modes: List(String),
    protocols: List(String),
    operations: List(String),
    capabilities: List(Capability),
  )
}

pub opaque type Registry {
  Registry(models: List(Model))
}

/// Explicit operator registrations only. No discovery calls or invented models.
pub fn new(models: List(Model)) -> Result(Registry, Failure) {
  let keys = list.map(models, fn(m) { #(m.provider, m.id) })
  case
    list.length(list.unique(keys)) != list.length(keys)
    || list.any(models, fn(m) {
      m.provider == ""
      || m.id == ""
      || m.auth_modes == []
      || m.protocols == []
      || m.operations == []
    })
  {
    True -> Error(Failure(InvalidConfiguration, NotSent, None))
    False -> Ok(Registry(models))
  }
}

pub fn models(registry: Registry) -> List(Model) {
  registry.models
}

pub fn resolve(registry: Registry, request: Request) -> Result(Model, Failure) {
  use model <- result.try(
    list.find(registry.models, fn(m) {
      m.provider == request.provider && m.id == request.model
    })
    |> result.replace_error(Failure(Unsupported, NotSent, None)),
  )
  let mode = case request.mode {
    Buffered -> Buffer
    Streaming -> Stream
  }
  case
    list.contains(model.auth_modes, request.auth_mode)
    && list.contains(model.protocols, request.protocol)
    && list.contains(model.operations, request.operation)
    && list.all([mode, ..request.required], fn(c) {
      list.contains(model.capabilities, c)
    })
    && request.session != ""
    && !{
      list.contains(request.required, Continuation)
      && request.pinned_account == None
    }
  {
    True -> Ok(model)
    False -> Error(Failure(Unsupported, NotSent, None))
  }
}
