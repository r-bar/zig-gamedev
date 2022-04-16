const std = @import("std");
const math = std.math;
const glfw = @import("glfw");
const zgpu = @import("zgpu");
const c = zgpu.cimgui;
const zm = @import("zmath");
const zmesh = @import("zmesh");
const znoise = @import("znoise");

const content_dir = @import("build_options").content_dir;
const window_title = "zig-gamedev: procedural mesh wgpu";

// zig fmt: off
const wgsl_vs =
\\  struct DrawUniforms {
\\      object_to_world: mat4x4<f32>;
\\  }
\\  @group(0) @binding(0) var<uniform> draw_uniforms: DrawUniforms;
\\
\\  struct FrameUniforms {
\\      world_to_clip: mat4x4<f32>;
\\  }
\\  @group(1) @binding(0) var<uniform> frame_uniforms: FrameUniforms;
\\
\\  struct VertexOut {
\\      @builtin(position) position_clip: vec4<f32>;
\\      @location(0) normal: vec3<f32>;
\\      @location(1) barycentrics: vec3<f32>;
\\  }
\\  @stage(vertex) fn main(
\\      @location(0) position: vec3<f32>,
\\      @location(1) normal: vec3<f32>,
\\      @builtin(vertex_index) vertex_index: u32,
\\  ) -> VertexOut {
\\     var output: VertexOut;
\\     output.position_clip = vec4(position, 1.0) * draw_uniforms.object_to_world * frame_uniforms.world_to_clip;
\\     output.normal = normal;
\\     let index = vertex_index % 3u;
\\     if (index == 0u) { output.barycentrics = vec3(1.0, 0.0, 0.0); }
\\     else if (index == 1u) { output.barycentrics = vec3(0.0, 1.0, 0.0); }
\\     else { output.barycentrics = vec3(0.0, 0.0, 1.0); }
\\     return output;
\\  }
;
const wgsl_fs =
\\  @stage(fragment) fn main(
\\      @location(0) normal: vec3<f32>,
\\      @location(1) barycentrics: vec3<f32>,
\\  ) -> @location(0) vec4<f32> {
\\      let color = normalize(abs(normal));
\\
\\      // wireframe
\\      var barys = barycentrics;
\\      barys.z = 1.0 - barys.x - barys.y;
\\      let deltas = fwidth(barys);
\\      let smoothing = deltas * 1.0;
\\      let thickness = deltas * 0.25;
\\      barys = smoothStep(thickness, thickness + smoothing, barys);
\\      let min_bary = min(barys.x, min(barys.y, barys.z));
\\      return vec4(min_bary * color, 1.0);
\\  }
// zig fmt: on
;

const Vertex = struct {
    position: [3]f32,
    normal: [3]f32,
};

const FrameUniforms = struct {
    world_to_clip: [16]f32,
};

const DrawUniforms = struct {
    object_to_world: [16]f32,
};

const Mesh = struct {
    index_offset: u32,
    vertex_offset: i32,
    num_indices: u32,
    num_vertices: u32,
};

const Drawable = struct {
    mesh_index: u32,
    position: [3]f32,
    basecolor_roughness: [4]f32,
};

const DemoState = struct {
    gctx: zgpu.GraphicsContext,
    stats: zgpu.FrameStats,

    pipeline: zgpu.RenderPipeline,
    draw_bind_group: zgpu.BindGroup,
    frame_bind_group: zgpu.BindGroup,

    total_num_vertices: u32,
    total_num_indices: u32,

    vertex_buffer: zgpu.Buffer,
    index_buffer: zgpu.Buffer,
    uniform_buffer: zgpu.Buffer,

    depth_texture: zgpu.Texture,
    depth_texture_view: zgpu.TextureView,

    meshes: std.ArrayList(Mesh),
    drawables: std.ArrayList(Drawable),

    camera: struct {
        position: [3]f32 = .{ 0.0, 4.0, -4.0 },
        forward: [3]f32 = .{ 0.0, 0.0, 1.0 },
        pitch: f32 = 0.15 * math.pi,
        yaw: f32 = 0.0,
    } = .{},
    mouse: struct {
        cursor: glfw.Window.CursorPos = .{ .xpos = 0.0, .ypos = 0.0 },
    } = .{},
};

fn appendMesh(
    mesh: zmesh.Mesh,
    meshes: *std.ArrayList(Mesh),
    meshes_indices: *std.ArrayList(u16),
    meshes_positions: *std.ArrayList([3]f32),
    meshes_normals: *std.ArrayList([3]f32),
) void {
    meshes.append(.{
        .index_offset = @intCast(u32, meshes_indices.items.len),
        .vertex_offset = @intCast(i32, meshes_positions.items.len),
        .num_indices = @intCast(u32, mesh.indices.len),
        .num_vertices = @intCast(u32, mesh.positions.len),
    }) catch unreachable;

    meshes_indices.appendSlice(mesh.indices) catch unreachable;
    meshes_positions.appendSlice(mesh.positions) catch unreachable;
    meshes_normals.appendSlice(mesh.normals.?) catch unreachable;
}

fn initScene(
    allocator: std.mem.Allocator,
    drawables: *std.ArrayList(Drawable),
    meshes: *std.ArrayList(Mesh),
    meshes_indices: *std.ArrayList(u16),
    meshes_positions: *std.ArrayList([3]f32),
    meshes_normals: *std.ArrayList([3]f32),
) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    zmesh.init(arena);
    defer zmesh.deinit();

    // Trefoil knot.
    {
        var mesh = zmesh.initTrefoilKnot(10, 128, 0.8);
        defer mesh.deinit();
        mesh.rotate(math.pi * 0.5, 1.0, 0.0, 0.0);
        mesh.unweld();
        mesh.computeNormals();

        drawables.append(.{
            .mesh_index = @intCast(u32, meshes.items.len),
            .position = .{ 0, 1, 0 },
            .basecolor_roughness = .{ 0.0, 0.7, 0.0, 0.6 },
        }) catch unreachable;

        appendMesh(mesh, meshes, meshes_indices, meshes_positions, meshes_normals);
    }
    // Parametric sphere.
    {
        var mesh = zmesh.initParametricSphere(20, 20);
        defer mesh.deinit();
        mesh.rotate(math.pi * 0.5, 1.0, 0.0, 0.0);
        mesh.unweld();
        mesh.computeNormals();

        drawables.append(.{
            .mesh_index = @intCast(u32, meshes.items.len),
            .position = .{ 3, 1, 0 },
            .basecolor_roughness = .{ 0.7, 0.0, 0.0, 0.2 },
        }) catch unreachable;

        appendMesh(mesh, meshes, meshes_indices, meshes_positions, meshes_normals);
    }
    // Icosahedron.
    {
        var mesh = zmesh.initIcosahedron();
        defer mesh.deinit();
        mesh.unweld();
        mesh.computeNormals();

        drawables.append(.{
            .mesh_index = @intCast(u32, meshes.items.len),
            .position = .{ -3, 1, 0 },
            .basecolor_roughness = .{ 0.7, 0.6, 0.0, 0.4 },
        }) catch unreachable;

        appendMesh(mesh, meshes, meshes_indices, meshes_positions, meshes_normals);
    }
    // Dodecahedron.
    {
        var mesh = zmesh.initDodecahedron();
        defer mesh.deinit();
        mesh.unweld();
        mesh.computeNormals();

        drawables.append(.{
            .mesh_index = @intCast(u32, meshes.items.len),
            .position = .{ 0, 1, 3 },
            .basecolor_roughness = .{ 0.0, 0.1, 1.0, 0.2 },
        }) catch unreachable;

        appendMesh(mesh, meshes, meshes_indices, meshes_positions, meshes_normals);
    }
    // Cylinder with top and bottom caps.
    {
        var disk = zmesh.initParametricDisk(10, 2);
        defer disk.deinit();
        disk.invert(0, 0);

        var cylinder = zmesh.initCylinder(10, 4);
        defer cylinder.deinit();

        cylinder.merge(disk);
        cylinder.translate(0, 0, -1);
        disk.invert(0, 0);
        cylinder.merge(disk);

        cylinder.scale(0.5, 0.5, 2);
        cylinder.rotate(math.pi * 0.5, 1.0, 0.0, 0.0);

        cylinder.unweld();
        cylinder.computeNormals();

        drawables.append(.{
            .mesh_index = @intCast(u32, meshes.items.len),
            .position = .{ -3, 0, 3 },
            .basecolor_roughness = .{ 1.0, 0.0, 0.0, 0.3 },
        }) catch unreachable;

        appendMesh(cylinder, meshes, meshes_indices, meshes_positions, meshes_normals);
    }
    // Torus.
    {
        var mesh = zmesh.initTorus(10, 20, 0.2);
        defer mesh.deinit();

        drawables.append(.{
            .mesh_index = @intCast(u32, meshes.items.len),
            .position = .{ 3, 1.5, 3 },
            .basecolor_roughness = .{ 1.0, 0.5, 0.0, 0.2 },
        }) catch unreachable;

        appendMesh(mesh, meshes, meshes_indices, meshes_positions, meshes_normals);
    }
    // Subdivided sphere.
    {
        var mesh = zmesh.initSubdividedSphere(3);
        defer mesh.deinit();
        mesh.unweld();
        mesh.computeNormals();

        drawables.append(.{
            .mesh_index = @intCast(u32, meshes.items.len),
            .position = .{ 3, 1, 6 },
            .basecolor_roughness = .{ 0.0, 1.0, 0.0, 0.2 },
        }) catch unreachable;

        appendMesh(mesh, meshes, meshes_indices, meshes_positions, meshes_normals);
    }
    // Tetrahedron.
    {
        var mesh = zmesh.initTetrahedron();
        defer mesh.deinit();
        mesh.unweld();
        mesh.computeNormals();

        drawables.append(.{
            .mesh_index = @intCast(u32, meshes.items.len),
            .position = .{ 0, 0.5, 6 },
            .basecolor_roughness = .{ 1.0, 0.0, 1.0, 0.2 },
        }) catch unreachable;

        appendMesh(mesh, meshes, meshes_indices, meshes_positions, meshes_normals);
    }
    // Octahedron.
    {
        var mesh = zmesh.initOctahedron();
        defer mesh.deinit();
        mesh.unweld();
        mesh.computeNormals();

        drawables.append(.{
            .mesh_index = @intCast(u32, meshes.items.len),
            .position = .{ -3, 1, 6 },
            .basecolor_roughness = .{ 0.2, 0.0, 1.0, 0.2 },
        }) catch unreachable;

        appendMesh(mesh, meshes, meshes_indices, meshes_positions, meshes_normals);
    }
    // Rock.
    {
        var rock = zmesh.initRock(123, 4);
        defer rock.deinit();
        rock.unweld();
        rock.computeNormals();

        drawables.append(.{
            .mesh_index = @intCast(u32, meshes.items.len),
            .position = .{ -6, 0, 3 },
            .basecolor_roughness = .{ 1.0, 1.0, 1.0, 1.0 },
        }) catch unreachable;

        appendMesh(rock, meshes, meshes_indices, meshes_positions, meshes_normals);
    }
    // Custom parametric (simple terrain).
    {
        const gen = znoise.FnlGenerator{
            .fractal_type = .fbm,
            .frequency = 2.0,
            .octaves = 5,
            .lacunarity = 2.02,
        };
        const local = struct {
            fn terrain(uv: *const [2]f32, position: *[3]f32, userdata: ?*anyopaque) callconv(.C) void {
                _ = userdata;
                position[0] = uv[0];
                position[1] = 0.025 * gen.noise2(uv[0], uv[1]);
                position[2] = uv[1];
            }
        };
        var ground = zmesh.initParametric(local.terrain, 40, 40, null);
        defer ground.deinit();
        ground.translate(-0.5, -0.0, -0.5);
        ground.invert(0, 0);
        ground.scale(20, 20, 20);
        ground.computeNormals();

        drawables.append(.{
            .mesh_index = @intCast(u32, meshes.items.len),
            .position = .{ 0, 0, 0 },
            .basecolor_roughness = .{ 0.1, 0.1, 0.1, 1.0 },
        }) catch unreachable;

        appendMesh(ground, meshes, meshes_indices, meshes_positions, meshes_normals);
    }
}

fn init(allocator: std.mem.Allocator, window: glfw.Window) DemoState {
    var gctx = zgpu.GraphicsContext.init(window);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const draw_bgl = gctx.device.createBindGroupLayout(
        &zgpu.BindGroupLayout.Descriptor{
            .entries = &.{
                zgpu.BindGroupLayout.Entry.buffer(0, .{ .vertex = true }, .uniform, true, 0),
            },
        },
    );
    defer draw_bgl.release();

    const frame_bgl = gctx.device.createBindGroupLayout(
        &zgpu.BindGroupLayout.Descriptor{
            .entries = &.{
                zgpu.BindGroupLayout.Entry.buffer(0, .{ .vertex = true }, .uniform, false, 0),
            },
        },
    );
    defer frame_bgl.release();

    const pl = gctx.device.createPipelineLayout(&zgpu.PipelineLayout.Descriptor{
        .bind_group_layouts = &.{ draw_bgl, frame_bgl },
    });
    defer pl.release();

    const pipeline = blk: {
        const vs_module = gctx.device.createShaderModule(&.{ .label = "vs", .code = .{ .wgsl = wgsl_vs } });
        defer vs_module.release();

        const fs_module = gctx.device.createShaderModule(&.{ .label = "fs", .code = .{ .wgsl = wgsl_fs } });
        defer fs_module.release();

        const color_target = zgpu.ColorTargetState{
            .format = zgpu.GraphicsContext.swapchain_format,
            .blend = &.{ .color = .{}, .alpha = .{} },
        };

        const vertex_attributes = [_]zgpu.VertexAttribute{
            zgpu.VertexAttribute{ .format = .float32x3, .offset = 0, .shader_location = 0 },
            zgpu.VertexAttribute{ .format = .float32x3, .offset = @sizeOf([3]f32), .shader_location = 1 },
        };
        const vertex_buffer_layout = zgpu.VertexBufferLayout{
            .array_stride = @sizeOf(Vertex),
            .attribute_count = vertex_attributes.len,
            .attributes = &vertex_attributes,
        };

        // Create a render pipeline.
        const pipeline_descriptor = zgpu.RenderPipeline.Descriptor{
            .layout = pl,
            .vertex = zgpu.VertexState{
                .module = vs_module,
                .entry_point = "main",
                .buffers = &.{vertex_buffer_layout},
            },
            .primitive = zgpu.PrimitiveState{
                .front_face = .ccw,
                .cull_mode = .none,
                .topology = .triangle_list,
            },
            .depth_stencil = &zgpu.DepthStencilState{
                .format = .depth32_float,
                .depth_write_enabled = true,
                .depth_compare = .less,
            },
            .fragment = &zgpu.FragmentState{
                .module = fs_module,
                .entry_point = "main",
                .targets = &.{color_target},
            },
        };
        break :blk gctx.device.createRenderPipeline(&pipeline_descriptor);
    };

    // Create an uniform buffer and a bind group for it.
    const uniform_buffer = gctx.device.createBuffer(&.{
        .usage = .{ .copy_dst = true, .uniform = true },
        .size = 64 * 1024,
    });

    const draw_bind_group = gctx.device.createBindGroup(
        &zgpu.BindGroup.Descriptor{
            .layout = draw_bgl,
            .entries = &.{zgpu.BindGroup.Entry.buffer(0, uniform_buffer, 512, @sizeOf(zm.Mat))},
        },
    );
    const frame_bind_group = gctx.device.createBindGroup(
        &zgpu.BindGroup.Descriptor{
            .layout = frame_bgl,
            .entries = &.{zgpu.BindGroup.Entry.buffer(0, uniform_buffer, 0, @sizeOf(zm.Mat))},
        },
    );

    var drawables = std.ArrayList(Drawable).init(allocator);
    var meshes = std.ArrayList(Mesh).init(allocator);
    var meshes_indices = std.ArrayList(u16).init(arena);
    var meshes_positions = std.ArrayList([3]f32).init(arena);
    var meshes_normals = std.ArrayList([3]f32).init(arena);
    initScene(allocator, &drawables, &meshes, &meshes_indices, &meshes_positions, &meshes_normals);

    const total_num_vertices = @intCast(u32, meshes_positions.items.len);
    const total_num_indices = @intCast(u32, meshes_indices.items.len);

    // Create a vertex buffer.
    const vertex_buffer = gctx.device.createBuffer(&.{
        .usage = .{ .copy_dst = true, .vertex = true },
        .size = total_num_vertices * @sizeOf(Vertex),
    });
    {
        var vertex_data = std.ArrayList(Vertex).init(arena);
        defer vertex_data.deinit();
        vertex_data.resize(total_num_vertices) catch unreachable;

        for (meshes_positions.items) |_, i| {
            vertex_data.items[i].position = meshes_positions.items[i];
            vertex_data.items[i].normal = meshes_normals.items[i];
        }
        gctx.queue.writeBuffer(vertex_buffer, 0, Vertex, vertex_data.items);
    }

    // Create an index buffer.
    const index_buffer = gctx.device.createBuffer(&.{
        .usage = .{ .copy_dst = true, .index = true },
        .size = total_num_indices * @sizeOf(u16),
    });
    gctx.queue.writeBuffer(index_buffer, 0, u16, meshes_indices.items);

    // Create a depth texture and it's 'view'.
    const fb_size = window.getFramebufferSize() catch unreachable;
    const depth = createDepthTexture(gctx.device, fb_size.width, fb_size.height);

    return .{
        .gctx = gctx,
        .stats = .{},
        .pipeline = pipeline,
        .draw_bind_group = draw_bind_group,
        .frame_bind_group = frame_bind_group,
        .total_num_vertices = total_num_vertices,
        .total_num_indices = total_num_indices,
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .uniform_buffer = uniform_buffer,
        .depth_texture = depth.texture,
        .depth_texture_view = depth.view,
        .meshes = meshes,
        .drawables = drawables,
    };
}

fn deinit(demo: *DemoState) void {
    demo.pipeline.release();
    demo.draw_bind_group.release();
    demo.frame_bind_group.release();
    demo.vertex_buffer.release();
    demo.index_buffer.release();
    demo.uniform_buffer.release();
    demo.depth_texture_view.release();
    demo.depth_texture.release();
    demo.meshes.deinit();
    demo.drawables.deinit();
    demo.gctx.deinit();
    demo.* = undefined;
}

fn update(demo: *DemoState) void {
    demo.stats.update(demo.gctx.window, window_title);
    zgpu.gui.newFrame();

    const window = demo.gctx.window;

    c.igSetNextWindowPos(
        c.ImVec2{ .x = 10.0, .y = 10.0 },
        c.ImGuiCond_FirstUseEver,
        c.ImVec2{ .x = 0.0, .y = 0.0 },
    );
    c.igSetNextWindowSize(.{ .x = 600.0, .y = -1 }, c.ImGuiCond_Always);

    _ = c.igBegin(
        "Demo Settings",
        null,
        c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoSavedSettings,
    );
    c.igBulletText("", "");
    c.igSameLine(0, -1);
    c.igTextColored(.{ .x = 0, .y = 0.8, .z = 0, .w = 1 }, "Right Mouse Button + drag", "");
    c.igSameLine(0, -1);
    c.igText(" :  rotate camera", "");

    c.igBulletText("", "");
    c.igSameLine(0, -1);
    c.igTextColored(.{ .x = 0, .y = 0.8, .z = 0, .w = 1 }, "W, A, S, D", "");
    c.igSameLine(0, -1);
    c.igText(" :  move camera", "");

    c.igEnd();

    // Handle camera rotation with mouse.
    {
        const cursor = window.getCursorPos() catch unreachable;
        const delta_x = @floatCast(f32, cursor.xpos - demo.mouse.cursor.xpos);
        const delta_y = @floatCast(f32, cursor.ypos - demo.mouse.cursor.ypos);
        demo.mouse.cursor.xpos = cursor.xpos;
        demo.mouse.cursor.ypos = cursor.ypos;

        if (window.getMouseButton(.right) == .press) {
            demo.camera.pitch += 0.0025 * delta_y;
            demo.camera.yaw += 0.0025 * delta_x;
            demo.camera.pitch = math.min(demo.camera.pitch, 0.48 * math.pi);
            demo.camera.pitch = math.max(demo.camera.pitch, -0.48 * math.pi);
            demo.camera.yaw = zm.modAngle(demo.camera.yaw);
        }
    }

    // Handle camera movement with 'WASD' keys.
    {
        const speed = zm.f32x4s(2.0);
        const delta_time = zm.f32x4s(demo.stats.delta_time);
        const transform = zm.mul(zm.rotationX(demo.camera.pitch), zm.rotationY(demo.camera.yaw));
        var forward = zm.normalize3(zm.mul(zm.f32x4(0.0, 0.0, 1.0, 0.0), transform));

        zm.store(demo.camera.forward[0..], forward, 3);

        const right = speed * delta_time * zm.normalize3(zm.cross3(zm.f32x4(0.0, 1.0, 0.0, 0.0), forward));
        forward = speed * delta_time * forward;

        var cpos = zm.load(demo.camera.position[0..], zm.Vec, 3);

        if (window.getKey(.w) == .press) {
            cpos += forward;
        } else if (window.getKey(.s) == .press) {
            cpos -= forward;
        }
        if (window.getKey(.d) == .press) {
            cpos += right;
        } else if (window.getKey(.a) == .press) {
            cpos -= right;
        }

        zm.store(demo.camera.position[0..], cpos, 3);
    }
}

fn draw(demo: *DemoState) void {
    var gctx = &demo.gctx;
    if (!gctx.update()) {
        // Release old depth texture.
        demo.depth_texture_view.release();
        demo.depth_texture.release();

        // Create a new depth texture to match the new window size.
        const depth = createDepthTexture(
            demo.gctx.device,
            gctx.swapchain_descriptor.width,
            gctx.swapchain_descriptor.height,
        );
        demo.depth_texture = depth.texture;
        demo.depth_texture_view = depth.view;
    }
    const fb_width = gctx.swapchain_descriptor.width;
    const fb_height = gctx.swapchain_descriptor.height;

    const cam_world_to_view = zm.lookToLh(
        zm.load(demo.camera.position[0..], zm.Vec, 3),
        zm.load(demo.camera.forward[0..], zm.Vec, 3),
        zm.f32x4(0.0, 1.0, 0.0, 0.0),
    );
    const cam_view_to_clip = zm.perspectiveFovLh(
        0.25 * math.pi,
        @intToFloat(f32, fb_width) / @intToFloat(f32, fb_height),
        0.01,
        200.0,
    );
    const cam_world_to_clip = zm.mul(cam_world_to_view, cam_view_to_clip);

    const back_buffer_view = gctx.swapchain.getCurrentTextureView();
    defer back_buffer_view.release();

    const commands = blk: {
        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();

        // Update camera xform.
        {
            var frame_uniforms: FrameUniforms = undefined;
            zm.storeMat(frame_uniforms.world_to_clip[0..], zm.transpose(cam_world_to_clip));
            encoder.writeBuffer(demo.uniform_buffer, 0, @TypeOf(frame_uniforms), &.{frame_uniforms});
        }

        if (demo.stats.frame_number == 1) {
            for (demo.drawables.items) |drawable, drawable_index| {
                const object_to_world = zm.translationV(
                    zm.load(drawable.position[0..], zm.Vec, 3),
                );
                var draw_uniforms: DrawUniforms = undefined;
                zm.storeMat(draw_uniforms.object_to_world[0..], zm.transpose(object_to_world));

                encoder.writeBuffer(
                    demo.uniform_buffer,
                    512 + 256 * drawable_index,
                    @TypeOf(draw_uniforms),
                    &.{draw_uniforms},
                );
            }
        }

        // Main pass.
        {
            const color_attachment = zgpu.RenderPassColorAttachment{
                .view = back_buffer_view,
                .load_op = .clear,
                .store_op = .store,
            };
            const depth_attachment = zgpu.RenderPassDepthStencilAttachment{
                .view = demo.depth_texture_view,
                .depth_load_op = .clear,
                .depth_store_op = .store,
                .depth_clear_value = 1.0,
                .stencil_load_op = .clear,
                .stencil_store_op = .store,
            };
            const render_pass_info = zgpu.RenderPassEncoder.Descriptor{
                .color_attachments = &.{color_attachment},
                .depth_stencil_attachment = &depth_attachment,
            };
            const pass = encoder.beginRenderPass(&render_pass_info);
            defer pass.release();

            pass.setVertexBuffer(0, demo.vertex_buffer, 0, demo.total_num_vertices * @sizeOf(Vertex));
            pass.setIndexBuffer(demo.index_buffer, .uint16, 0, demo.total_num_indices * @sizeOf(u16));

            pass.setPipeline(demo.pipeline);
            pass.setBindGroup(1, demo.frame_bind_group, &.{});

            for (demo.drawables.items) |drawable, drawable_index| {
                pass.setBindGroup(0, demo.draw_bind_group, &.{@intCast(u32, drawable_index * 256)});
                pass.drawIndexed(
                    demo.meshes.items[drawable.mesh_index].num_indices,
                    1,
                    demo.meshes.items[drawable.mesh_index].index_offset,
                    demo.meshes.items[drawable.mesh_index].vertex_offset,
                    0,
                );
            }
            pass.end();
        }

        // Gui pass.
        {
            const color_attachment = zgpu.RenderPassColorAttachment{
                .view = back_buffer_view,
                .load_op = .load,
                .store_op = .store,
            };
            const render_pass_info = zgpu.RenderPassEncoder.Descriptor{
                .color_attachments = &.{color_attachment},
            };
            const pass = encoder.beginRenderPass(&render_pass_info);
            defer pass.release();

            zgpu.gui.draw(pass);

            pass.end();
        }

        break :blk encoder.finish(null);
    };
    defer commands.release();

    gctx.queue.submit(&.{commands});
    gctx.swapchain.present();
}

fn createDepthTexture(device: zgpu.Device, width: u32, height: u32) struct {
    texture: zgpu.Texture,
    view: zgpu.TextureView,
} {
    const texture = device.createTexture(&zgpu.Texture.Descriptor{
        .usage = .{ .render_attachment = true },
        .dimension = .dimension_2d,
        .size = .{ .width = width, .height = height, .depth_or_array_layers = 1 },
        .format = .depth32_float,
        .mip_level_count = 1,
        .sample_count = 1,
    });
    const view = texture.createView(&zgpu.TextureView.Descriptor{
        .format = .depth32_float,
        .dimension = .dimension_2d,
        .base_mip_level = 0,
        .mip_level_count = 1,
        .base_array_layer = 0,
        .array_layer_count = 1,
        .aspect = .depth_only,
    });
    return .{ .texture = texture, .view = view };
}

pub fn main() !void {
    try glfw.init(.{});
    defer glfw.terminate();

    const window = try glfw.Window.create(1280, 960, window_title, null, null, .{
        .client_api = .no_api,
        .cocoa_retina_framebuffer = true,
    });
    defer window.destroy();
    try window.setSizeLimits(.{ .width = 400, .height = 400 }, .{ .width = null, .height = null });

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var demo = init(allocator, window);
    defer deinit(&demo);

    zgpu.gui.init(window, demo.gctx.device, content_dir ++ "Roboto-Medium.ttf", 25.0);
    defer zgpu.gui.deinit();

    while (!window.shouldClose()) {
        try glfw.pollEvents();
        update(&demo);
        draw(&demo);
    }
}
