// MIT License

// Copyright (c) 2022 Nathan V. Morrical

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

// public VKRT API
#include <vkrt.h>
// our device-side data structures
#include "deviceCode.h"
// external helper stuff for image output
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb/stb_image_write.h"

#define LOG(message)                                            \
  std::cout << VKRT_TERMINAL_BLUE;                               \
  std::cout << "#vkrt.sample(main): " << message << std::endl;   \
  std::cout << VKRT_TERMINAL_DEFAULT;
#define LOG_OK(message)                                         \
  std::cout << VKRT_TERMINAL_LIGHT_BLUE;                         \
  std::cout << "#vkrt.sample(main): " << message << std::endl;   \
  std::cout << VKRT_TERMINAL_DEFAULT;

extern "C" char simpleRayGen_spv[];
extern "C" uint32_t simpleRayGen_spv_size;

#include <iostream>
int main(int ac, char **av) 
{
    LOG("vkrt example '" << av[0] << "' starting up");

    // Initialize Vulkan, and create a "vkrt device," a context to hold the
    // ray generation shader and output buffer. The "1" is the number of devices requested.
    VKRTContext vkrt = vkrtContextCreate(nullptr, 1);

    // OWLModule module
        // = owlModuleCreate(owl,deviceCode_ptx);
    
    VKRTVarDecl rayGenVars[]
        = {
        { "fbPtr",  VKRT_BUFPTR, VKRT_OFFSETOF(RayGenData,fbPtr) },
        { "fbSize", VKRT_INT2,   VKRT_OFFSETOF(RayGenData,fbSize) },
        { "color0", VKRT_FLOAT3, VKRT_OFFSETOF(RayGenData,color0) },
        { "color1", VKRT_FLOAT3, VKRT_OFFSETOF(RayGenData,color1) },
        { /* sentinel: */ nullptr }
    };
    // Allocate room for one RayGen shader, create it, and
    // hold on to it with the "owl" context
    VKRTRayGen rayGen
        = vkrtRayGenCreate(vkrt,
                        simpleRayGen_spv_size, simpleRayGen_spv,
                        sizeof(RayGenData),rayGenVars,-1);

    // (re-)builds all optix programs, with current pipeline settings
    // vkrtBuildPrograms(vkrt);

    // Create the pipeline. Note that vkrt will (kindly) warn there are no geometry and no miss programs defined.
    vkrtBuildPipeline(vkrt);

    // Now finally, cleanup
    vkrtRayGenRelease(rayGen);
    vkrtContextDestroy(vkrt);
}

