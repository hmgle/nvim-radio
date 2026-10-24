-- Minimal SQLite3 binding for LuaJIT via FFI.
-- Covers the API surface the store needs: open/exec/prepare/bind/step/column.
local ffi = require("ffi")

local M = {}

ffi.cdef([[
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
typedef long long sqlite3_int64;
typedef unsigned long long sqlite3_uint64;

int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
int sqlite3_close(sqlite3 *db);
int sqlite3_close_v2(sqlite3 *db);
const char *sqlite3_errmsg(sqlite3 *db);
int sqlite3_extended_errcode(sqlite3 *db);
int sqlite3_exec(sqlite3 *db, const char *sql,
  int (*callback)(void*,int,char**,char**), void *arg, char **errmsg);
int sqlite3_prepare_v2(sqlite3 *db, const char *sql, int nbyte,
  sqlite3_stmt **ppStmt, const char **pzTail);
int sqlite3_step(sqlite3_stmt *stmt);
int sqlite3_reset(sqlite3_stmt *stmt);
int sqlite3_finalize(sqlite3_stmt *stmt);
int sqlite3_bind_parameter_count(sqlite3_stmt *stmt);
int sqlite3_bind_parameter_index(sqlite3_stmt *stmt, const char *name);
int sqlite3_bind_null(sqlite3_stmt *stmt, int idx);
int sqlite3_bind_int(sqlite3_stmt *stmt, int idx, int value);
int sqlite3_bind_int64(sqlite3_stmt *stmt, int idx, sqlite3_int64 value);
int sqlite3_bind_double(sqlite3_stmt *stmt, int idx, double value);
int sqlite3_bind_text(sqlite3_stmt *stmt, int idx, const char *value, int n, void(*)(void*));
int sqlite3_bind_blob(sqlite3_stmt *stmt, int idx, const void *value, int n, void(*)(void*));
int sqlite3_column_count(sqlite3_stmt *stmt);
const char *sqlite3_column_name(sqlite3_stmt *stmt, int idx);
int sqlite3_column_type(sqlite3_stmt *stmt, int idx);
const unsigned char *sqlite3_column_text(sqlite3_stmt *stmt, int idx);
const void *sqlite3_column_blob(sqlite3_stmt *stmt, int idx);
int sqlite3_column_bytes(sqlite3_stmt *stmt, int idx);
sqlite3_int64 sqlite3_column_int64(sqlite3_stmt *stmt, int idx);
double sqlite3_column_double(sqlite3_stmt *stmt, int idx);
sqlite3_int64 sqlite3_last_insert_rowid(sqlite3 *db);
int sqlite3_changes(sqlite3 *db);
int sqlite3_total_changes(sqlite3 *db);
int sqlite3_busy_timeout(sqlite3 *db, int ms);
const char *sqlite3_libversion(void);
void sqlite3_free(void *ptr);
]])

local SQLITE_OK = 0
local SQLITE_ROW = 100
local SQLITE_DONE = 101
local SQLITE_TRANSIENT = ffi.cast("void(*)(void*)", -1)
local SQLITE_STATIC = ffi.cast("void(*)(void*)", 0)

M.SQLITE_INTEGER = 1
M.SQLITE_FLOAT = 2
M.SQLITE_TEXT = 3
M.SQLITE_BLOB = 4
M.SQLITE_NULL = 5

local CANDIDATES = {
  "sqlite3",
  "/usr/lib/x86_64-linux-gnu/libsqlite3.so.0",
  "/usr/lib/aarch64-linux-gnu/libsqlite3.so.0",
  "/usr/lib/libsqlite3.so.0",
  "/usr/lib/x86_64-linux-gnu/libsqlite3.so",
  "/usr/lib/libsqlite3.dylib",
  "/opt/homebrew/lib/libsqlite3.dylib",
}

---Load libsqlite3; returns the library namespace or nil plus an error.
function M.load()
  local errors = {}
  for _, name in ipairs(CANDIDATES) do
    local ok, lib = pcall(ffi.load, name)
    if ok and lib then
      return lib
    end
    errors[#errors + 1] = name .. ": " .. tostring(lib)
  end
  return nil, table.concat(errors, "; ")
end

local lib, lib_err = M.load()
M.lib = lib

---@return boolean
function M.available()
  return lib ~= nil
end

---@return string
function M.load_error()
  return lib_err or ""
end

---@return string
function M.version()
  if not lib then
    return "unavailable"
  end
  return ffi.string(lib.sqlite3_libversion())
end

local function errmsg(db)
  if db == nil then
    return "unknown sqlite error"
  end
  return ffi.string(lib.sqlite3_errmsg(db))
end

---Statement wrapper: bind parameters, step rows, read columns.
local Stmt = {}
Stmt.__index = Stmt

---@param stmt_cdata ffi.cdata*
---@param db table
function Stmt._new(stmt_cdata, db)
  local self = setmetatable({}, Stmt)
  self._ptr = ffi.gc(stmt_cdata, lib.sqlite3_finalize)
  self._db = db
  self._count = lib.sqlite3_column_count(self._ptr)
  self._names = {}
  for i = 0, self._count - 1 do
    self._names[i + 1] = ffi.string(lib.sqlite3_column_name(self._ptr, i))
  end
  return self
end

---Column names, in order.
---@return string[]
function Stmt:columns()
  return vim.deepcopy(self._names)
end

---@return integer
function Stmt:column_count()
  return self._count
end

---@param params table|nil numeric (positional) or string (named) keys
---@return boolean ok, string|nil err
function Stmt:bind(params)
  if not params then
    return true
  end
  local param_count = lib.sqlite3_bind_parameter_count(self._ptr)
  for key, value in pairs(params) do
    local index
    if type(key) == "number" then
      index = key
    elseif type(key) == "string" then
      index = lib.sqlite3_bind_parameter_index(self._ptr, key)
      if index == 0 then
        index = lib.sqlite3_bind_parameter_index(self._ptr, ":" .. key)
      end
      if index == 0 then
        return false, "no such parameter: " .. key
      end
    else
      return false, "invalid parameter key"
    end
    if index < 1 or index > param_count then
      return false, "parameter index out of range: " .. tostring(index)
    end
    local code
    local t = type(value)
    if value == nil then
      code = lib.sqlite3_bind_null(self._ptr, index)
    elseif t == "number" then
      if value % 1 == 0 and math.abs(value) < 2 ^ 53 then
        code = lib.sqlite3_bind_int64(self._ptr, index, math.floor(value))
      else
        code = lib.sqlite3_bind_double(self._ptr, index, value)
      end
    elseif t == "boolean" then
      code = lib.sqlite3_bind_int64(self._ptr, index, value and 1 or 0)
    else
      code = lib.sqlite3_bind_text(self._ptr, index, value, #value, SQLITE_TRANSIENT)
    end
    if code ~= SQLITE_OK then
      return false, errmsg(self._db._ptr)
    end
  end
  return true
end

---Read the current row as a table keyed by column name.
---@return table
function Stmt:row()
  local out = {}
  for i = 1, self._count do
    local kind = lib.sqlite3_column_type(self._ptr, i - 1)
    local name = self._names[i]
    if kind == M.SQLITE_NULL then
      out[name] = nil
    elseif kind == M.SQLITE_INTEGER then
      out[name] = tonumber(lib.sqlite3_column_int64(self._ptr, i - 1))
    elseif kind == M.SQLITE_FLOAT then
      out[name] = tonumber(lib.sqlite3_column_double(self._ptr, i - 1))
    else
      local len = lib.sqlite3_column_bytes(self._ptr, i - 1)
      local text = lib.sqlite3_column_text(self._ptr, i - 1)
      if text == nil then
        out[name] = nil
      elseif len > 0 then
        out[name] = ffi.string(text, len)
      else
        out[name] = ""
      end
    end
  end
  return out
end

---Advance one step.
---@return "row"|"done"|nil, string|nil err
function Stmt:step()
  local code = lib.sqlite3_step(self._ptr)
  if code == SQLITE_ROW then
    return "row"
  end
  if code == SQLITE_DONE then
    return "done"
  end
  return nil, errmsg(self._db._ptr)
end

function Stmt:reset()
  lib.sqlite3_reset(self._ptr)
end

function Stmt:finalize()
  lib.sqlite3_finalize(ffi.gc(self._ptr, nil))
end

---Collect every remaining row.
---@return table[]
function Stmt:rows()
  local out = {}
  while true do
    local status, err = self:step()
    if status == "row" then
      out[#out + 1] = self:row()
    elseif status == "done" then
      break
    else
      error("sqlite step failed: " .. tostring(err), 2)
    end
  end
  return out
end

---Collect the first row, if any.
---@return table|nil
function Stmt:first_row()
  local status, err = self:step()
  if status == "row" then
    return self:row()
  end
  if status == nil then
    error("sqlite step failed: " .. tostring(err), 2)
  end
  return nil
end

---Database wrapper.
local Db = {}
Db.__index = Db

---@param path string
---@return table|nil db, string|nil err
function M.open(path)
  if not lib then
    return nil, "libsqlite3 unavailable: " .. tostring(lib_err)
  end
  local ptr = ffi.new("sqlite3*[1]")
  local SQLITE_OPEN_READWRITE = 0x00000002
  local SQLITE_OPEN_CREATE = 0x00000004
  local SQLITE_OPEN_FULLMUTEX = 0x00010000
  local flags = bit.bor(SQLITE_OPEN_READWRITE, SQLITE_OPEN_CREATE, SQLITE_OPEN_FULLMUTEX)
  local code = lib.sqlite3_open_v2(path, ptr, flags, nil)
  if code ~= SQLITE_OK then
    local message = errmsg(ptr[0])
    if ptr[0] ~= nil then
      lib.sqlite3_close_v2(ptr[0])
    end
    return nil, message
  end
  local self = setmetatable({}, Db)
  self._ptr = ffi.gc(ptr[0], lib.sqlite3_close_v2)
  self.path = path
  lib.sqlite3_busy_timeout(self._ptr, 5000)
  return self
end

---@return string|nil err
function Db:errmsg()
  return errmsg(self._ptr)
end

---Execute one or more statements without parameters.
---@param sql string
---@return boolean ok, string|nil err
function Db:exec(sql)
  local errptr = ffi.new("char*[1]")
  local code = lib.sqlite3_exec(self._ptr, sql, nil, nil, errptr)
  if code ~= SQLITE_OK then
    local message = errptr[0] ~= nil and ffi.string(errptr[0]) or errmsg(self._ptr)
    if errptr[0] ~= nil then
      lib.sqlite3_free(errptr[0])
    end
    return false, message
  end
  return true
end

---@param sql string
---@return table|nil stmt, string|nil err
function Db:prepare(sql)
  local out = ffi.new("sqlite3_stmt*[1]")
  local code = lib.sqlite3_prepare_v2(self._ptr, sql, #sql, out, nil)
  if code ~= SQLITE_OK then
    return nil, errmsg(self._ptr)
  end
  return Stmt._new(out[0], self)
end

---Prepare, bind, and run a statement to completion.
---@param sql string
---@param params table|nil
---@return table[] rows, integer changes
function Db:execute(sql, params)
  local stmt, err = self:prepare(sql)
  if not stmt then
    error("sqlite prepare failed: " .. tostring(err), 2)
  end
  local ok, bind_err = stmt:bind(params)
  if not ok then
    stmt:finalize()
    error("sqlite bind failed: " .. tostring(bind_err), 2)
  end
  local rows = stmt:rows()
  stmt:finalize()
  return rows, self:changes()
end

---@return integer
function Db:changes()
  return tonumber(lib.sqlite3_changes(self._ptr)) or 0
end

---@return integer
function Db:total_changes()
  return tonumber(lib.sqlite3_total_changes(self._ptr)) or 0
end

---@return integer
function Db:last_insert_rowid()
  return tonumber(lib.sqlite3_last_insert_rowid(self._ptr)) or 0
end

---Run a function inside an IMMEDIATE transaction; rolls back on error.
---@param fn function
---@return any
function Db:transaction(fn)
  local ok, err = self:exec("BEGIN IMMEDIATE")
  if not ok then
    error("sqlite begin failed: " .. tostring(err), 2)
  end
  local results = { pcall(fn) }
  local success = table.remove(results, 1)
  if success then
    local committed, commit_err = self:exec("COMMIT")
    if not committed then
      self:exec("ROLLBACK")
      error("sqlite commit failed: " .. tostring(commit_err), 2)
    end
    return unpack(results)
  end
  self:exec("ROLLBACK")
  error(results[1], 2)
end

---@param pragma string
---@return string
function Db:pragma(pragma)
  local rows = self:execute("PRAGMA " .. pragma)
  local first = rows[1] or {}
  for _, value in pairs(first) do
    return tostring(value)
  end
  return ""
end

function Db:close()
  if self._ptr and not self._closed then
    self._closed = true
    ffi.gc(self._ptr, nil)
    lib.sqlite3_close_v2(self._ptr)
  end
end

M._STATIC = SQLITE_STATIC
return M
