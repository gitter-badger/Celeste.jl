using Celeste
using CelesteTypes

using DataFrames
using SampleData

using ForwardDiff
using DualNumbers
import Transform
import Optim
import JLD

include("src/interpolating_linesearch.jl")

# Note that the u hessians are no good.
#omitted_ids = Int64[ids_free.u, ids_free.k[:], ids_free.c2[:], ids_free.r2];
#omitted_ids = ids_free.u;

galaxy_ids = union(ids_free.c1[:,2],
                   ids_free.c2[:,2],
                   ids_free.r1[2],
                   ids_free.r2[2],
                   ids_free.k[:,2],
                   ids_free.e_dev, ids_free.e_axis, ids_free.e_angle, ids_free.e_scale);

star_ids = union(ids_free.c1[:,1],
                   ids_free.c2[:,1],
                   ids_free.r1[1],
                   ids_free.r2[1],
                   ids_free.k[:,1]);


transform = Transform.free_transform;

jld_file = "$dat_dir/SDSS_blob.jld"


simulation = false
if simulation
    #blob, mp_original, body = gen_sample_star_dataset()
    blob, mp_original, body = gen_sample_galaxy_dataset(perturb=true);
    #blob, mp_original, body = gen_three_body_dataset(perturb=true); # Too slow.
else
    # An actual celestial body.
    field_dir = joinpath(dat_dir, "sample_field")
    run_num = "003900"
    camcol_num = "6"
    field_num = "0269"

    original_blob = SDSS.load_sdss_blob(field_dir, run_num, camcol_num, field_num);
    # Can't write a WCS pointer to a JLD file.
    #JLD.save(jld_file, "original_blob", original_blob)

    # Need to do this until WCS has an actual deep copy.
    original_crpix_band = Float64[unsafe_load(original_blob[b].wcs.crpix, i) for i=1:2, b=1:5];
    function reset_crpix!(blob)
        for b=1:5
            unsafe_store!(blob[b].wcs.crpix, original_crpix_band[1, b], 1)
            unsafe_store!(blob[b].wcs.crpix, original_crpix_band[2, b], 2)
        end
    end

    original_cat_df = SDSS.load_catalog_df(field_dir, run_num, camcol_num, field_num);
    cat_loc = convert(Array{Float64}, original_cat_df[[:ra, :dec]]);

    obj_cols = [:objid, :is_star, :is_gal, :psfflux_r, :compflux_r, :ra, :dec];
    sort(original_cat_df[original_cat_df[:is_gal] .== true, obj_cols], cols=:compflux_r, rev=true)
    sort(original_cat_df[original_cat_df[:is_gal] .== false, obj_cols], cols=:psfflux_r, rev=true)

    objid = "1237662226208063541" # A bright star with bad pixels    
    #objid = "1237662226208063576" # A galaxy
    #objid = "1237662226208063565" # A brightish star but with good pixels.
    obj_row = original_cat_df[:objid] .== objid;
    obj_loc = Float64[original_cat_df[obj_row, :ra][1], original_cat_df[obj_row, :dec][1]]

    blob = deepcopy(original_blob);
    reset_crpix!(blob)
    WCS.world_to_pixel(blob[3].wcs, obj_loc)
    width = 15.
    x_ranges, y_ranges = SDSS.crop_image!(blob, width, obj_loc);
    @assert SDSS.test_catalog_entry_in_image(blob, obj_loc)
    entry_in_image = [SDSS.test_catalog_entry_in_image(blob, cat_loc[i,:][:]) for i=1:size(cat_loc, 1)];
    original_cat_df[entry_in_image, obj_cols]
    cat_entries = SDSS.convert_catalog_to_celeste(original_cat_df[entry_in_image, :], blob)
    mp_original = ModelInit.cat_init(cat_entries, patch_radius=20.0, tile_width=5);
end

for b=1:5
    writedlm("/tmp/pixels_$b.csv", blob[b].pixels, ',')
end


# fit_star = false
# if fit_star
#     # Optimize only the star parameters.
#     omitted_ids = sort(unique(union(galaxy_ids, ids_free.a, ids_free.u)));
#     epsilon = 1e-6
#     for s=1:mp_original.S
#         mp_original.vp[s][ids.a] = [ 1.0 - epsilon, epsilon ]
#     end
# else
#     # Optimize only the galaxy parameters.
#     omitted_ids = sort(unique(union(star_ids, ids_free.a, ids_free.u)));
#     epsilon = 1e-6
#     for s=1:mp_original.S
#         mp_original.vp[s][ids.a] = [ epsilon, 1.0 - epsilon ]
#     end
# end

for s in 1:mp_original.S
    mp_original.vp[s][ids.a] = [ 0.5, 0.5 ]
end
omitted_ids = Int64[]
kept_ids = setdiff(1:length(ids_free), omitted_ids)

lbs, ubs = OptimizeElbo.get_nlopt_bounds(mp_original.vp[1]);

##############
# Get a BFGS fit for comparison
mp_fit = deepcopy(mp_original);
iter_count, max_f, max_x, ret = OptimizeElbo.maximize_f(ElboDeriv.elbo, blob, mp_fit, transform, omitted_ids=omitted_ids, verbose=true);
fit_v = ElboDeriv.elbo(blob, mp_fit).v;


#########################
# Newton's method by hand

obj_wrap = OptimizeElbo.ObjectiveWrapperFunctions(
    mp -> ElboDeriv.elbo(blob, mp), deepcopy(mp_original), transform, kept_ids, omitted_ids);
obj_wrap.state.scale = -1.0 # For minimization, which is required by the linesearch algorithm.

x0 = transform.vp_to_vector(mp_original.vp, omitted_ids);
elbo_grad = zeros(Float64, length(x0));
elbo_hess = zeros(Float64, length(x0), length(x0));

max_iters = 10;

d = Optim.DifferentiableFunction(obj_wrap.f_value, obj_wrap.f_grad!, obj_wrap.f_value_grad!);

f_vals = zeros(Float64, max_iters);
cumulative_iters = zeros(Int64, max_iters);
x_vals = [ zeros(Float64, length(x_old)) for iter=1:max_iters ];
grads = [ zeros(Float64, length(x_old)) for iter=1:max_iters ];

# warm start with BFGS
warm_start = false
if warm_start
    mp_start = deepcopy(mp_original)
    start_iter_count, start_f, x_start = OptimizeElbo.maximize_f(ElboDeriv.elbo, blob, mp_start, Transform.free_transform, omitted_ids=omitted_ids, ftol_abs=1);
    obj_wrap.state.f_evals = start_iter_count;
    x_new = deepcopy(x_start); # For quick restarts while debugging
    new_val = old_val = -start_f;
else
    x_new = transform.vp_to_vector(mp_original.vp, omitted_ids);
    obj_wrap.state.f_evals = 0
end

for iter in 1:max_iters
    println("-------------------$iter")
    x_old = deepcopy(x_new);
    old_val = new_val;

    elbo_hess = obj_wrap.f_ad_hessian(x_new);
    hess_ev = eig(elbo_hess)[1]
    min_ev = minimum(hess_ev)
    max_ev = maximum(hess_ev)
    println("========= Eigenvalues: $(max_ev), $(min_ev)")
    if min_ev < 0
        println("========== Warning -- non-convex, $(min_ev)")
        elbo_hess += eye(length(x_new)) * abs(min_ev) * 2
        hess_ev = eig(elbo_hess)[1]
        min_ev = minimum(hess_ev)
        max_ev = maximum(hess_ev)
        println("========= New eigenvalues: $(max_ev), $(min_ev)")
    end
    # if abs(max_ev) / abs(min_ev) > 1e6
    #     println("Regularizing hessian")
    #     elbo_hess += eye(length(x_new)) * (abs(max_ev) / 1e6)
    #     hess_ev = eig(elbo_hess)[1]
    #     min_ev = minimum(hess_ev)
    #     max_ev = maximum(hess_ev)
    #     println("========= New eigenvalues: $(max_ev), $(min_ev)")
    # end
    f_val, gr_new = obj_wrap.f_value_grad(x_old);
    x_direction = -(elbo_hess \ gr_new)

    lsr = Optim.LineSearchResults(Float64); # Not used
    c = -1.; # Not used
    mayterminate = true; # Not used
    pre_linesearch_iters = obj_wrap.state.f_evals
    interpolating_linesearch!(d, x_old, x_direction,
                              x_new, gr_new,
                              lsr, c, mayterminate;
                              c1 = 1e-4,
                              c2 = 0.9,
                              rho = 2.0, verbose=false);
    new_val, gr_new = obj_wrap.f_value_grad(x_new)
    println("Spent $(obj_wrap.state.f_evals - pre_linesearch_iters) iterations on linesearch for an extra $(f_val - new_val).")
    val_diff = new_val / old_val - 1
    f_vals[iter] = new_val;
    x_vals[iter] = deepcopy(x_new)
    grads[iter] = deepcopy(gr_new)
    cumulative_iters[iter] = obj_wrap.state.f_evals
    println(">>>>>>  Current value after $(obj_wrap.state.f_evals) evaluations: $(new_val) (BFGS got $(-fit_v) in $(iter_count) iters)")
    mp_nm = deepcopy(mp_original);
    transform.vector_to_vp!(x_new, mp_nm.vp, omitted_ids);
    #println(ElboDeriv.get_brightness(mp_nm))
    println("\n\n")
end

# f_vals are negative because it's minimization
println("Newton objective - BFGS objective (higher is better)")
println("Cumulative fuction evaluation ratio:")
hcat(((-f_vals) - fit_v) / abs(fit_v), cumulative_iters ./ iter_count)

reduce(hcat, [ x_diff ./ x_vals[1] for x_diff in diff(x_vals) ])

mp_nm = deepcopy(mp_original);
transform.vector_to_vp!(x_new, mp_nm.vp, omitted_ids);

print_params(mp_original, mp_nm, mp_fit)

ElboDeriv.get_brightness(mp_nm)
ElboDeriv.get_brightness(mp_fit)
ElboDeriv.get_brightness(mp_original)



####################
# Newton's method with our own hessian regularization

obj_wrap = OptimizeElbo.ObjectiveWrapperFunctions(
    mp -> ElboDeriv.elbo(blob, mp), deepcopy(mp_original), transform, kept_ids, omitted_ids);
obj_wrap.state.scale = -1.0 # For minimization, which is required by the linesearch algorithm.
obj_wrap.state.print_every_n = 1
obj_wrap.state.verbose = true

function f_hess_reg!(x, new_hess)
    hess = obj_wrap.f_ad_hessian(x)
    hess_ev = eig(hess)[1]
    min_ev = minimum(hess_ev)
    max_ev = maximum(hess_ev)

    # Make it positive definite.
    if min_ev < 0
        hess += eye(length(x_new)) * abs(min_ev) * 2
    end

    new_hess[:,:] = hess
end

x0 = transform.vp_to_vector(mp_original.vp, omitted_ids);
nm_result = Optim.optimize(obj_wrap.f_value, obj_wrap.f_grad!, f_hess_reg!, x0, method = :newton)

