-- Provides
--   Syntax sugar support for as3 module
--   as3.class()
--   as3.namespace()

--[[

obj * newindex -> as3.set
obj * index -> callobj
obj * call -> error
callobj * index -> callobj.value * index -> callobj
callobj * newindex -> callobj.value * newindex -> as3.set
callobj * as3.any -> as3.any(callobj.value, ...)
callobj * call -> as3.call(callobj.value, ...)
callobj * tostring -> as3.call(callobj.value, "toString")

--]]

local old_trace, old_call, old_tolua, old_type = as3.trace, as3.call, as3.tolua, as3.type

local spam = as3.trace

local proxy_tag = newproxy()

local unproxy = function(o)
  local mt = getmetatable(o)
  if mt and mt[1] == proxy_tag then
    o = mt:value()
  end
  return o
end

do
  local make_callobj
  do
    local index = function(t, k)
      --spam("callobj index", k)
      return make_callobj(getmetatable(t):value(), k)
    end

    local newindex = function(t, k, v)
      --spam("callobj newindex", k)
      as3.set(getmetatable(t):value(), k, v)
    end

    -- Enforcing dot notation for performance
    local call = function(t, ...)
      local mt = getmetatable(t) -- Note no value() call here
      --spam("callobj call", mt.obj_, mt.key_)
      return as3.call(mt.obj_, mt.key_, ...)
    end

    local value = function(self)
      --spam("callobj value", self.value_ ~= nil, self.obj_, self.key_)
      if self.value_ == nil then
        self.value_ = as3.get(self.obj_, self.key_)
      end
      return self.value_
    end

    make_callobj = function(t, k)
      if not as3.isas3value(t) then
        error("as3 object expected, got "..(as3.type(t) or type(t)))
      end
      return setmetatable(
          {},
          {
            proxy_tag;

            obj_ = t;
            key_ = k;
            value_ = nil;

            value = value;

            __index = index;
            __newindex = newindex;
            __call = call;
          }
        )
    end
  end

  do -- Patch as3 metatable
    local mt = debug.getmetatable(assert(as3.new("String")))

    mt.__index = function(t, k)
      return make_callobj(t, k)
    end

    mt.__newindex = function(t, k, v)
      return as3.set(t, k, v)
    end

    mt.__tostring = function(t)
      local str = old_call(t, "toString")
      local tt = type(str)
      if tt == "number" then
        str = tostring(str)
      elseif tt ~= "string" then
        --old_trace("BAD2", tt, old_type(str), type(str), type(t), old_type(t))
        str = "("..(old_type(t) or type(t))..")" -- TODO: Dump something meaningful!
      end
      return str
    end
  end

  do -- Patch methods
    local methods =
    {
      "release", "tolua", "get", "set", "assign",
      "call", "type", "namespacecall", "trace",
      "newclass", "newclass2", "new", "new2", "isas3value"
    }

    for _, name in ipairs(methods) do
      local old_fn = as3[name]
      as3[name] = function(...)
        --[[
        if name ~= "trace" then
          --spam("[as3.sugar]", name, "args:", ...)
        end
        --]]
        local n = select("#", ...)
        local args = {}
        for i = 1, n do
          args[i] = unproxy(select(i, ...))
        end
        return old_fn(unpack(args, 1, n))
      end
    end
  end
end

--[[

as3.class * newindex -> error
as3.class * index -> pkgobj(nil)
as3.class * call(path) -> pkgobj/CLASS(splitpath(path))
as3.namespace * call(path) -> pkgobj/NAMESPACE(splitpath(path))

splitpath(path) -> namespace, class, key

pkgobj * index(key) ->
  pkgobj.namespace = pkgobj.namespace.."."..pkgobj.class
  pkgobj.class = pkgobj.key
  pkgobj.key = key

pkgobj * as3.any -> as3.any(as3.get(as3.newclass2(pkgobj.namespace, pkgobj.class), pkgobj.key)))

pkgobj/NAMESPACE * dot_call(pkgobj, ...) ->
  as3.namespacecall(pkgobj.namespace.."."..pkgobj.class, pkgobj.key, ...)

pkgobj/CLASS * dot_call(...) ->
  if pkgobj.key == "new" then
    as3.new2(pkgobj.namespace, pkgobj.class, ...)
  elseif pkgobj.key == "class" then
    as3.newclass2(pkgobj.namespace, pkgobj.class, ...)
  else
    as3.call(as3.newclass2(pkgobj.namespace, pkgobj.class), pkgobj.key, ...)
  end

pkgobj * newindex(key, value) ->
  pkgobj.namespace = pkgobj.namespace.."."..pkgobj.class
  pkgobj.class = pkgobj.key
  pkgobj.key = key
  as3.set(as3.newclass2(pkgobj.namespace, pkgobj.class), pkgobj.key, value)

--]]

do -- as3.class(), as3.namespace()
  do
    local CLASS = "class"
    local NAMESPACE = "namespace"

    local make_pkgobj
    do
      local pkgobj_proxy_tag = newproxy()

      local splitpath = function(...) -- TODO: Test this well!
        -- TODO: Huge overhead, but simple. Rewrite.

        local str = table.concat({...}, "."):gsub(":+", ".")
        local buf = {}
        for match in str:gmatch("([^.:]+)") do
          buf[#buf + 1] = match
        end

        local key = table.remove(buf)
        local class = table.remove(buf)
        local namespace = table.concat(buf, ".")

        return namespace, class, key
      end

      local path2 = function(self, ...)
        local class = assert(self.key_, "path is empty")

        local namespace = self.class_
        if namespace and namespace ~= "" then
          local prefix = self.namespace_
          if prefix and prefix ~= "" then
            namespace = prefix .. "." .. namespace
          end
        else
          namespace = self.namespace_
        end

        return namespace, class, ...
      end

      local value = function(self)
        if self.value_ == nil then
          if self.kind_ ~= CLASS then
            error("namespace objects can not be resolved to actual value") -- TODO: Really?
          end
          --spam("value", self.namespace_, self.class_, self.key_)
          self.value_ = as3.get(as3.newclass2(self.namespace_, self.class_), self.key_)
        end
        return self.value_
      end

      local call = function(t, ...)
        local mt = assert(getmetatable(t))

        local key = mt.key_

        --spam("call begin", mt.kind_, mt.namespace_, mt.class_, mt.key_)

        -- TODO: Colon call attempt gives really misleading error message. Improve it.

        -- TODO: Actually it should be two separate call() implementations.
        if mt.kind_ == CLASS then
          if key == "new" then
            -- new object mode
            --spam("new call", mt.namespace_, mt.class_, mt.key_)
            local result = as3.new2(mt.namespace_, mt.class_, ...)

            -- Note it is impossible to create a new instance of null.
            -- use as3.toas3(nil) for this.
            -- TODO: Detect we did not wanted to actually create null instance
            --       and remove this restriction.
            assert(as3.type(result) ~= "null", "new2 failed")

            --spam("created", as3.type(result), result)

            return result
          elseif key == "class" then
            -- class object mode
            --spam("class call", mt.namespace_, mt.class_, mt.key_)
            local result = as3.newclass2(mt.namespace_, mt.class_, ...)
            assert(as3.type(result) ~= "null", "newclass2 failed (class call)")
            return result
          end

          -- dot call mode
          --spam("dot call", mt.namespace_, mt.class_, mt.key_)
          local classobj = as3.newclass2(mt.namespace_, mt.class_)
          assert(as3.type(classobj) ~= "null", "newclass2 failed (static call)")
          return as3.call(classobj, key, ...)
        end

        assert(mt.kind_ == NAMESPACE)

        -- namespace call mode
        --spam("namespace call", mt.namespace_, mt.class_, mt.key_)
        return as3.namespacecall(mt.namespace_.."."..mt.class_, key, ...)
      end

      local newindex = function(t, k, v)
        -- Note subindices in k are not supported
        --spam("newindex", getmetatable(t).kind_, getmetatable(t):path2(k))
        local mt = getmetatable(t)
        if mt.kind_ ~= CLASS then
          error("namespace objects are read-only") -- TODO: Really?
        end
        as3.set(as3.newclass2(mt:path2()), k, v)
      end

      local index = function(t, k)
        --spam("index", getmetatable(t).kind_, getmetatable(t):path2(k))
        local mt = getmetatable(t)
        return make_pkgobj(mt.kind_, mt:path2(k))
      end

      local tostring_pkgobj = function(t) -- TODO: This function always MUST return string!
        local namespace, path = getmetatable(t):path2()
        if namespace then
          path = tostring(namespace) .. "::" .. tostring(path)
        end
        return path
      end

      make_pkgobj = function(pkgobj_kind, ...)
        local namespace, class, key = splitpath(...)
        return setmetatable(
            {},
            {
              proxy_tag;
              pkgobj_proxy_tag;

              kind_ = pkgobj_kind;

              namespace_ = namespace;
              class_ = class;
              key_ = key;
              value_ = nil;

              path2 = path2;
              value = value;

              __index = index;
              __newindex = newindex;
              __call = call;
              __tostring = tostring_pkgobj;
            }
          )
      end
    end

    local make_pkgobj_table = function(pkgobj_kind)
      return setmetatable(
          {},
          {
            __index = function(t, k)
              return make_pkgobj(pkgobj_kind, k)
            end;

            __call = function(t, ...)
              return make_pkgobj(pkgobj_kind, ...)
            end;

            __newindex = function(t, k, v)
              error("attempted to write to a read-only table")
            end;
          }
        )
    end

    as3.class = make_pkgobj_table(CLASS)
    as3.namespace = make_pkgobj_table(NAMESPACE)
  end
end
