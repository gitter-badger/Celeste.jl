module Synthetic

export gen_blob

using CelesteTypes
import ModelInit
import Util

import Distributions

# Generate synthetic data.

function wrapped_poisson(rate::Float64)
    0 < rate ? float(rand(Distributions.Poisson(rate))) : 0.
end


function get_patch(the_mean::Vector{Float64}, H::Int64, W::Int64)
    const radius = 50.
    hm, wm = int(the_mean)
    w11 = max(1, wm - radius):min(W, wm + radius)
    h11 = max(1, hm - radius):min(H, hm + radius)
    return(w11, h11)
end


function write_gaussian(the_mean, the_cov, intensity, pixels)
    the_precision = the_cov^-1
    c = det(the_precision)^.5 / 2pi
    y = Array(Float64, 2)

    H, W = size(pixels)
    w_range, h_range = get_patch(the_mean, H, W)

    for w in w_range, h in h_range
        y[1] = the_mean[1] - h
        y[2] = the_mean[2] - w
        ypy = Util.matvec222(the_precision, y)
        pdf_hw = c * exp(-0.5 * ypy)
        pixel_rate = intensity * pdf_hw
        pixels[h, w] += wrapped_poisson(pixel_rate)
    end

    pixels
end


function write_star(img0::Image, ce::CatalogEntry, pixels::Matrix{Float64})
    # TODO: move this to use world coordinates.
    for k in 1:length(img0.psf)
        the_mean = ce.pos + img0.psf[k].xiBar
        the_cov = img0.psf[k].tauBar
        intensity = ce.star_fluxes[img0.b] * img0.iota * img0.psf[k].alphaBar
        write_gaussian(the_mean, the_cov, intensity, pixels)
    end
end


function write_galaxy(img0::Image, ce::CatalogEntry, pixels::Matrix{Float64})
    # TODO: move this to use world coordinates.
    e_devs = [ce.gal_frac_dev, 1 - ce.gal_frac_dev]

    XiXi = Util.get_bvn_cov(ce.gal_ab, ce.gal_angle, ce.gal_scale)

    for i in 1:2
        for gproto in galaxy_prototypes[i]
            for k in 1:length(img0.psf)
                the_mean = ce.pos + img0.psf[k].xiBar
                the_cov = img0.psf[k].tauBar + gproto.nuBar * XiXi
                intensity = ce.gal_fluxes[img0.b] * img0.iota *
                    img0.psf[k].alphaBar * e_devs[i] * gproto.etaBar
                write_gaussian(the_mean, the_cov, intensity, pixels)
            end
        end
    end
end


function gen_image(img0::Image, n_bodies::Vector{CatalogEntry})
    pixels = reshape(float(rand(Distributions.Poisson(img0.epsilon * img0.iota),
                     img0.H * img0.W)), img0.H, img0.W)
    # TODO: move this to use world coordinates.

    for body in n_bodies
        body.is_star ? write_star(img0, body, pixels) : write_galaxy(img0, body, pixels)
    end

    return Image(img0.H, img0.W, pixels, img0.b, img0.wcs, img0.epsilon,
            img0.iota, img0.psf, img0.run_num, img0.camcol_num, img0.field_num)
end


function gen_blob(blob0::Blob, n_bodies::Vector{CatalogEntry})
    [gen_image(blob0[b], n_bodies) for b in 1:5]
end


#######################################

const pp = ModelInit.sample_prior()


function sample_fluxes(i::Int64, r_s)
#    r_s = rand(Distributions.Gamma(pp.r[i][1], pp.r[i][2]))
    k_s = rand(Distributions.Categorical(pp.k[i]))
    c_s = rand(Distributions.MvNormal(pp.c[i][:, k_s], pp.c[i][:, :, k_s]))

    l_s = Array(Float64, 5)
    l_s[3] = r_s
    l_s[4] = l_s[3] * exp(c_s[3])
    l_s[5] = l_s[4] * exp(c_s[4])
    l_s[2] = l_s[3] / exp(c_s[2])
    l_s[1] = l_s[2] / exp(c_s[1])
    l_s
end


function synthetic_body(ce::CatalogEntry)
    ce2 = deepcopy(ce)
#    ce2.is_star = rand(Distributions.Bernoulli(pp.a[1]))
    ce2.star_fluxes[:] = sample_fluxes(1, ce.star_fluxes[3])
    ce2.gal_fluxes[:] = sample_fluxes(2, ce.gal_fluxes[3])
    ce2
end


function synthetic_bodies(n_bodies::Vector{CatalogEntry})
    CatalogEntry[synthetic_body(ce) for ce in n_bodies]
end


end

