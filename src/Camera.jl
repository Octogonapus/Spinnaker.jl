# Spinnaker.jl: wrapper for FLIR/Point Grey Spinnaker SDK
# Copyright (C) 2019 Samuel Powell

# Camera.jl: interface to Camera objects
export serial, model, vendor, isrunning, start!, stop!, getimage, getimage!, saveimage,
  triggermode, triggermode!,
  triggersource, triggersource!,
  trigger!,
  exposure, exposure!, exposure_limits,
  autoexposure_limits, autoexposure_limits!,
  framerate, framerate!, framerate_limits,
  gain, gain!, gain_limits,
  adcbits, adcbits!,
  gammaenable!,
  pixelformat, pixelformat!,
  acquisitionmode, acquisitionmode!,
  sensordims, imagedims, imagedims!, imagedims_limits, offsetdims, offsetdims!, offsetdims_limits,
  buffercount, buffercount!, buffermode, buffermode!, bufferunderrun, bufferfailed,
  reset!, powersupplyvoltage

_CURRENT_CAMS_LOCK = ReentrantLock()
_CURRENT_CAMS = []

"""
 Spinnaker SDK Camera object

 Create a camera object by referencing a CameraList, e.g.,
 `cl = CameraList()
  cam = cl[0]`

  The camera is initialised when created and deinitialised when garbage collected.
"""
mutable struct Camera
  handle::spinCamera
  names::Dict{String,String}

  function Camera(handle)
    @assert spinsys.handle != C_NULL
    @assert handle != C_NULL
    spinCameraDeInit(handle)
    spinCameraInit(handle)
    names = Dict{String,String}()
    cam = new(handle, names)
    lock(_CURRENT_CAMS_LOCK) do
      push!(_CURRENT_CAMS, cam)
    end
    finalizer(_release!, cam)

    # Activate chunk mode
    set!(SpinBooleanNode(cam, "ChunkModeActive"), true)
    _chunkselect(cam, ["FrameID", "FrameCounter"], "frame indentification")
    _chunkselect(cam, ["ExposureTime"], "exposure time")
    _chunkselect(cam, ["Timestamp"], "timestamps")

    # Discover ambiguous names
    cam.names["AutoExposureTimeLowerLimit"] = "AutoExposureTimeLowerLimit"
    cam.names["AutoExposureTimeUpperLimit"] = "AutoExposureTimeUpperLimit"
    cam.names["AcquisitionFrameRateEnabled"] = "AcquisitionFrameRateEnabled"

    try
      Spinnaker.get(Spinnaker.SpinFloatNode(cam, "AutoExposureTimeLowerLimit"))
    catch
      cam.names["AutoExposureTimeLowerLimit"] = "AutoExposureExposureTimeLowerLimit"
      cam.names["AutoExposureTimeUpperLimit"] = "AutoExposureExposureTimeUpperLimit"
    end
    try
      Spinnaker.get(Spinnaker.SpinBooleanNode(cam, "AcquisitionFrameRateEnabled"))
    catch
      cam.names["AcquisitionFrameRateEnabled"] = "AcquisitionFrameRateEnable"
    end


    return cam
  end
end


# Attempt to activate chunk data for each entry in chunknames
# - this allows chunk names to differ on cameras
function _chunkselect(cam::Camera, chunknames::Vector{String}, desc::String)

  fail = true
  i = 1
  while fail == true
    try
      fail = false
      set!(SpinEnumNode(cam, "ChunkSelector"), chunknames[i])
      set!(SpinBooleanNode(cam, "ChunkEnable"), true)
    catch e
      fail = true
    end
    i += 1
  end

  if fail
    @warn "Unable to enable chunk data for $(desc), tried $(chunknames), metadata may be incorrect"
  end

end

unsafe_convert(::Type{spinCamera}, cam::Camera) = cam.handle
unsafe_convert(::Type{Ptr{spinCamera}}, cam::Camera) = pointer_from_objref(cam)

function _reinit(cam::Camera)
  spinCameraDeInit(cam)
  spinCameraInit(cam)
  return cam
end

# Release handle to system
function _release!(cam::Camera)
  if cam.handle != C_NULL
    # if there is another handle to the same camera, do not release that handle because we will break the other one.
    # that camera will release itself when its the last one.
    our_serial = serial(cam)
    lock(_CURRENT_CAMS_LOCK) do
      for i in eachindex(_CURRENT_CAMS)
        test_cam = _CURRENT_CAMS[i]
        if serial(test_cam) == our_serial
          deleteat!(_CURRENT_CAMS, i)
          cam.handle = C_NULL
          @async println("did not release cam")
          return
        end
      end
    end

    # we are the last camera with this handle, so release it
    try
      stop!(cam)
    catch e
    end
    spinCameraDeInit(cam)
    spinCameraRelease(cam)
    cam.handle = C_NULL
    @async println("released cam")
  end
  return nothing
end

"""
  isinitialized(cam::Camera) -> Bool

Determine if the camera is initialized.
"""
function isinitialized(cam::Camera)
  pbIsInitialized = Ref(bool8_t(false))
  spinCameraIsInitialized(cam, pbIsInitialized)
  return (pbIsInitialized[] == 0x01)
end

"""
  reset!(cam::Camera; wait = false, timeout = nothing)

Immediately reset and reboot the camera, after which the camera will need re-initialization via `CameraList`.
Or to automatically wait to reconnect to a camera with the same serial number set `wait` to `true`, and a maximum
timeout in seconds via `timeout`.
"""
function reset!(cam::Camera; wait::Bool=false, timeout::Union{Int,Nothing}=nothing)
  # get these before resetting
  timeout_secs = if wait
    isnothing(timeout) ? get(SpinIntegerNode(cam, "MaxDeviceResetTime")) / 1e3 : timeout
  end
  sn = wait ? serial(cam) : nothing

  hNodeMap = Ref(spinNodeMapHandle(C_NULL))
  spinCameraGetNodeMap(cam, hNodeMap)

  hDeviceReset = Ref(spinNodeHandle(C_NULL))
  spinNodeMapGetNode(hNodeMap[], "DeviceReset", hDeviceReset)
  spinCommandExecute(hDeviceReset[])

  if wait
    timeout = Timer(timeout_secs)
    while isopen(timeout)
      try
        cam = find_cam_with_serial(CameraList(), sn)
        isnothing(cam) || return cam
      catch ex
        @debug "waiting during reset!" exception = ex
        sleep(0.5)
      end
    end
    isopen(timeout) || error("Spinnaker timed out waiting for the camera with serial number $(sn) to reappear after reset")
  end
  return cam
end

# Include subfiles
include(joinpath("camera", "acquisition.jl"))
include(joinpath("camera", "analog.jl"))
include(joinpath("camera", "format.jl"))
include(joinpath("camera", "stream.jl"))
include(joinpath("camera", "digitalio.jl"))

#
# Device metadata
#

"""
  serial(::Camera) -> String

  Return camera serial number (string)
"""
serial(cam::Camera) = get(SpinStringNode(cam, "DeviceSerialNumber", CameraTLDeviceNodeMap()))

"""
  vendor(::Camera) -> String

  Return vendor name of specified camera.
"""
vendor(cam::Camera) = get(SpinStringNode(cam, "DeviceVendorName", CameraTLDeviceNodeMap()))

"""
  model(::Camera) -> String

  Return model name of specified camera.
"""
model(cam::Camera) = get(SpinStringNode(cam, "DeviceModelName", CameraTLDeviceNodeMap()))

"""
  show(::IO, ::Camera)

  Write details of camera to supplied IO.
"""
function show(io::IO, cam::Camera)
  vendorname = vendor(cam)
  modelname = model(cam)
  serialno = serial(cam)
  write(io, "$vendorname $modelname ($serialno)")
end

#
# Device status
#

"""
  devicetemperature(cam::Camera, location::String) -> Float

  Return the temperature of the specified device location.
"""
function devicetemperature(cam::Camera, location::String)
  set!(SpinEnumNode(cam, "DeviceTemperatureSelector"), location)
  return Spinnaker.get(Spinnaker.SpinFloatNode(cam, "DeviceTemperature"))
end

"""
  powersupplyvoltage(cam::Camera) -> Float

  Return the device power supply voltage in Volts.
"""
powersupplyvoltage(cam::Camera) = Spinnaker.get(Spinnaker.SpinFloatNode(cam, "PowerSupplyVoltage"))

#
# Image acquistion
#

"""
  acquisitionmode(::Camera) -> String

  Return camera acquistion mode.
"""
acquisitionmode(cam::Camera) = get(SpinEnumNode(cam, "AcquisitionMode"))

"""
  acquisitionmode!(::Camera, ::AbstractString) -> String

  Set camera acquistion mode, returns set mode.
"""
acquisitionmode!(cam::Camera, mode) = set!(SpinEnumNode(cam, "AcquisitionMode"), mode)


function _isimagecomplete(himage_ref)
  isIncomplete = Ref(bool8_t(false))
  spinImageIsIncomplete(himage_ref[], isIncomplete)
  if isIncomplete == true
    imageStatus = Ref(spinImageStatus(IMAGE_NO_ERROR))
    spinImageGetStatus(himage_ref[], imageStatus)
    spinImageRelease(himage_ref[])
    @warn "Image incomplete with error $(imageStatus)"
    return false
  else
    return true
  end
end

#
# Image retrieval -> SpinImage
#

"""
  getimage(::Camer; release=true, timeout=-1) -> Image

  Copy the next image from the specified camera, blocking until available unless a timeout of >= 0 (ms) is specified. If release
  is false, the image buffer is not released.
"""
getimage(cam::Camera; release=true, timeout=-1) = getimage!(cam, SpinImage(), release=release, timeout=timeout)


"""
  getimage!(::Camera, ::SpinImage; release=true, timeout=-1) -> Image

  Copy the next image from the specified camera, blocking until available unless a timeout of >= 0 (ms) is specified, overwriting existing.
  If releaseis false, the image buffer is not released.
"""
function getimage!(cam::Camera, image::SpinImage; release=true, timeout=-1)

  # Get image handle and check it's complete
  himage_ref = Ref(spinImage(C_NULL))
  if timeout == -1
    spinCameraGetNextImage(cam, himage_ref)
  else
    spinCameraGetNextImageEx(cam, timeout, himage_ref)
  end
  @assert _isimagecomplete(himage_ref)

  # Create output image, copy and release buffer
  spinImageDeepCopy(himage_ref[], image)
  if release
    spinImageRelease(himage_ref[])
  end

  return image

end


#
# Image retrieval -> CameraImage
#

"""
  getimage(::Camera, ::Type{T}; normalize=true; release=true, timeout=-1) -> CameraImage

  Copy the next image from the specified camera, converting the image data to the specified array
  format, blocking until available unless a timeout of >= 0 (ms) is specified. If release is false, the image buffer is not released.

  If `normalize == false`, the input data from the camera is interpreted as a number in the range of
  the underlying type, e.g., for a camera operating in Mono8 pixel format, a call
  `getimage!(cam, Float64, normalize=false)` will return an array of dobule precision numbers in
  the range [0, 255]. `If normalize == true` the input data is interpreted as an associated fixed point
  format, and thus the array will be in the range [0,1].

  To return images compatible with Images.jl, one can request a Gray value, e.g.,
  `getimage!(cam, Gray{N0f8}, normalize=true)`.

  Function also returns image ID and timestamp metadata.
"""
function getimage(cam::Camera, ::Type{T}; normalize=true, release=true, timeout=-1) where {T}

  himage_ref, width, height, id, timestamp, exposure = _pullim(cam, timeout=timeout)
  imdat = Array{T,2}(undef, (width, height))
  camim = CameraImage(imdat, id, timestamp, exposure)
  _copyimage!(himage_ref[], width, height, camim, normalize)
  if release
    spinImageRelease(himage_ref[])
  end
  return camim

end


"""
  getimage!(::Camera, ::CameraImage{T,2}; normalize=false; release=true, timeout=-1)

  Copy the next iamge from the specified camera, converting to the format of, and overwriting the
  provided CameraImage, blocking until available unless a timeout of >= 0 (ms) is specified. If release is
  false, the image buffer is not released.

  If `normalize == false`, the input data from the camera is interpreted as a number in the range of
  the underlying type, e.g., for a camera operating in Mono8 pixel format, a call
  `getimage!(cam, Float64, normalize=false)` will return an array of dobule precision numbers in
  the range [0, 255]. `If normalize == true` the input data is interpreted as an associated fixed point
  format, and thus the array will be in the range [0,1].

  To return images compatible with Images.jl, one can request a Gray value, e.g.,
  `getimage!(cam, Gray{N0f8}, normalize=true)`.
"""
function getimage!(cam::Camera, image::CameraImage{T,2}; normalize=true, release=true, timeout=-1) where {T}

  himage_ref, width, height, id, timestamp, exposure = _pullim(cam, timeout=timeout)
  camim = CameraImage(image.data, id, timestamp, exposure)
  _copyimage!(himage_ref[], width, height, camim, normalize)
  if release
    spinImageRelease(himage_ref[])
  end
  return camim

end

function _pullim(cam::Camera; timeout=-1)

  # Get image handle and check it's complete
  himage_ref = Ref(spinImage(C_NULL))
  if timeout == -1
    spinCameraGetNextImage(cam, himage_ref)
  else
    spinCameraGetNextImageEx(cam, timeout, himage_ref)
  end
  if !_isimagecomplete(himage_ref)
    spinImageRelease(himage_ref[])
    throw(ErrorException("Image not complete"))
  end

  # Get image dimensions, ID and timestamp
  width = Ref(Csize_t(0))
  height = Ref(Csize_t(0))
  id = Ref(Int64(0))
  timestamp = Ref(Int64(0))
  exposure = Ref(Float64(0))
  spinImageGetWidth(himage_ref[], width)
  spinImageGetHeight(himage_ref[], height)
  spinImageChunkDataGetIntValue(himage_ref[], "ChunkFrameID", id)
  spinImageChunkDataGetFloatValue(himage_ref[], "ChunkExposureTime", exposure)
  spinImageChunkDataGetIntValue(himage_ref[], "ChunkTimestamp", timestamp)
  return himage_ref, Int(width[]), Int(height[]), id[], timestamp[], exposure[]

end


#
# Image retrieval -> Array
#

"""
  getimage!(::Camera, ::AbstractArray{T,2}; normalize=false, release=true, timeout=-1)

  Copy the next iamge from the specified camera, converting to the format of, and overwriting the
  provided abstract array, blocking until available unless a timeout of >= 0 (ms) is specified. If release
  is false, the image buffer is not released.

  If `normalize == false`, the input data from the camera is interpreted as a number in the range of
  the underlying type, e.g., for a camera operating in Mono8 pixel format, a call
  `getimage!(cam, Array{Float64}(undef, dims...), normalize=false)` will return an array of dobule
  precision numbers in the range [0, 255]. `If normalize == true` the input data is interpreted as
  an associated fixed point format, and thus the array will be in the range [0,1].
"""
function getimage!(cam::Camera, image::AbstractArray{T,2}; normalize=true, release=true, timeout=-1) where {T}

  himage_ref, width, height, id, timestamp, exposure = _pullim(cam, timeout=timeout)
  _copyimage!(himage_ref[], width, height, image, normalize)
  if release
    spinImageRelease(himage_ref[])
  end
  return id, timestamp, exposure

end


#
# Image retrieval -> File
#

"""
    saveimage()::Camera, fn::AbstractString, ::spinImageFileFormat; release=true, timeout=-1)

    Save the next image from the specified camera to file `fn`, blocking until available unless
    a timeout of >= 0 (ms) is specified. If release is false, the image buffer is not released.
"""
function saveimage(cam::Camera, fn::AbstractString, fmt::spinImageFileFormat; release=true, timeout=-1)

  # Get image handle and check it's complete
  himage_ref = Ref(spinImage(C_NULL))
  if timeout == -1
    spinCameraGetNextImage(cam, himage_ref)
  else
    spinCameraGetNextImageEx(cam, timeout, himage_ref)
  end
  @assert _isimagecomplete(himage_ref)
  spinImageSave(himage_ref[], fn, fmt)
  if release
    spinImageRelease(himage_ref[])
  end

end
