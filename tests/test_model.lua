local H = require("tests.helpers")

return function()
  local model = require("radio.model")
  local store = assert(require("radio.store").open(H.tmpdir("model") .. "/radio.db"))
  -- Mirrors radio-cli/src/model.rs: Option fields without skip_serializing_if
  -- serialize as null, while an absent track is omitted.
  local fixtures = vim.json.decode(
    table.concat(vim.fn.readfile(H.root .. "/tests/fixtures/radio-cli-recordings.json"), "\n")
  )
  for _, fixture in ipairs(fixtures) do
    local json = vim.json.encode(fixture)
    store._db:execute(
      "INSERT INTO recordings VALUES (?1,?2,?3,0)",
      { fixture.id, fixture.status, json }
    )
    local decoded = model.decode_recording(json)
    local loaded = store:recording(fixture.id)
    H.eq(decoded.error, nil, "CLI null error decodes to nil")
    H.eq(loaded.error, nil, "CLI null error loads from the database as nil")
    H.eq(loaded.track, nil, "omitted CLI track stays optional")
    H.check(
      vim.deep_equal(model.decode_recording(model.encode_recording(loaded)), loaded),
      "CLI recording round trip"
    )
  end
  local active = store:recording("cli-recording")
  H.eq(active.stopped_at, nil, "null stopped_at is optional")
  H.eq(active.media_duration_ms, nil, "null duration is optional")
  H.eq(active.final_path, nil, "null final_path is optional")
  H.eq(
    model.recording({ recovery_pending = vim.NIL }).recovery_pending,
    false,
    "null is not a true recovery flag"
  )
  H.eq(model.recording({ track = vim.NIL }).track, nil, "constructors normalize explicit null too")
  local station = model.decode('{"name":null,"url_resolved":null,"active":null}')
  H.eq(station.name, "", "null station name uses the default")
  H.eq(station:primary_url(), "", "null station URL uses the default")
  H.eq(station.active, false, "null station flag uses the default")
  store:close()
end
