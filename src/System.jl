# Spinnaker.jl: wrapper for FLIR/Point Grey Spinnaker SDK
# Copyright (C) 2019 Samuel Powell

# System.jl: interface to Spinnaker system

"""
  Spinnaker SDK system object.

  System() returns new System object from which interfaces and devices can be discovered.
"""
mutable struct System
  handle::spinSystem

  function System()
    hsystem_ref = Ref(spinSystem(C_NULL))
    spinSystemGetInstance(hsystem_ref)
    @assert hsystem_ref[] != C_NULL
    sys = new(hsystem_ref[])
    finalizer(_release!, sys)
    return sys
  end
end

unsafe_convert(::Type{spinSystem}, sys::System) = sys.handle
unsafe_convert(::Type{Ptr{spinSystem}}, sys::System) = pointer_from_objref(sys)

_DEFERRED_SYSTEM_LOCK = ReentrantLock()
_DEFERRED_SYSTEM = Ref{Union{System,Nothing}}(nothing)

function _maybe_release_system()
  while !trylock(_DEFERRED_SYSTEM_LOCK)
    GC.safepoint()
  end
  try
    if _DEFERRED_SYSTEM[].handle != C_NULL
      _release!(_DEFERRED_SYSTEM[])
    end
  finally
    unlock(_DEFERRED_SYSTEM_LOCK)
  end
  return nothing
end

# Release handle to system
function _release!(sys::System)
  if sys.handle == C_NULL
    return nothing
  end

  while !trylock(_CURRENT_CAM_SERIALS_LOCK)
    GC.safepoint()
  end
  try
    if !isempty(_CURRENT_CAM_SERIALS)
      while !trylock(_DEFERRED_SYSTEM_LOCK)
        GC.safepoint()
      end
      try
        _DEFERRED_SYSTEM[] = sys
      finally
        unlock(_DEFERRED_SYSTEM_LOCK)
      end
    else
      _do_release!(sys)
    end
  finally
    unlock(_CURRENT_CAM_SERIALS_LOCK)
  end
  return nothing
end

function _do_release!(sys::System)
  if sys.handle != C_NULL
    spinSystemReleaseInstance(sys)
    sys.handle = C_NULL
  end
  return nothing
end

"""
  version(::System)-> version, build

  Query the version number of the Spinnaker library in use. Returns a VersionNumber object
  and seperate build number.
"""
function version(sys::System)
  hlibver_ref = Ref(spinLibraryVersion(0, 0, 0, 0))
  spinSystemGetLibraryVersion(sys, hlibver_ref)
  libver = VersionNumber(hlibver_ref[].major, hlibver_ref[].minor, hlibver_ref[].type)
  return libver, hlibver_ref[].build
end
