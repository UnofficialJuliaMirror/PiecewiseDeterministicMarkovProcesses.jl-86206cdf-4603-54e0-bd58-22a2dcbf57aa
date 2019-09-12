### WARNING This is an old ODE solver which is not based on an iterator implementation. We keep it until LSODA has an iterator implementation

include("chvdiffeq.jl")

function solve(problem::PDMPProblem, algo::CHV{Tode}; verbose::Bool = false, ind_save_d=-1:1, ind_save_c=-1:1, dt=0.001, n_jumps = Inf64, reltol = 1e-7, abstol = 1e-9, save_positions = (false, true), save_rate = false) where {Tode <: Symbol}
	verbose && println("#"^30)
	ode = algo.ode
	@assert ode in [:cvode, :lsoda, :adams, :bdf]

	# initialise the problem. If I call twice this solve function, it should give the same result...
	init!(problem)

	# we declare the characteristics for convenience
	caract = problem.caract

	ti, tf = problem.tspan
	n_jumps  += 1 # to hold initial vector
	nsteps  = 1 # index for the current jump number

	xc0 = problem.caract.xc0
	xd0 = problem.caract.xd0

	# Set up initial simulation time
	t = ti

	X_extended = similar(xc0, length(xc0) + 1)
	for ii in eachindex(xc0)
		X_extended[ii] = xc0[ii]
	end
	X_extended[end] = ti

	t_hist  = [ti]

	#useful to use the same array, as it can be used in CHV(ode)
	Xd = problem.caract.xd
	if ind_save_c[1] == -1
		ind_save_c = 1:length(xc0)
	end

	if ind_save_d[1] == -1
		ind_save_d = 1:length(xd0)
	end
	xc_hist = VectorOfArray([copy(xc0)[ind_save_c]])
	xd_hist = VectorOfArray([copy(xd0)[ind_save_d]])
	rate_hist = eltype(xc0)[]

	res_ode = zeros(2, length(X_extended))

	nsteps += 1

	deltaxd = copy(problem.caract.pdmpjump.nu[1,:]) # declare this variable, variable to hold discrete jump
	numpf   = size(problem.caract.pdmpjump.nu,1)    # number of reactions
	rate    = zeros(numpf)  # vector of rates

	# define the ODE flow, this leads to big memory saving
	if ode == :cvode || ode == :bdf
		Flow = (X0_,Xd_,Δt,r_) -> Sundials.cvode((tt,x,xdot) -> algo(xdot, x, problem.caract, tt), X0_, [0., Δt], abstol = abstol, reltol = reltol, integrator = :BDF)
	elseif	ode==:adams
		Flow = (X0_,Xd_,Δt,r_) -> Sundials.cvode((tt,x,xdot) -> algo(xdot, x, problem.caract, tt), X0_, [0., Δt], abstol = abstol, reltol = reltol, integrator = :Adams)
	elseif ode==:lsoda
		Flow = (X0_,Xd_,Δt,r_) -> LSODA.lsoda((tt,x,xdot,data) -> algo(xdot, x, problem.caract, tt), X0_, [0., Δt], abstol = abstol, reltol = reltol)
	end

	# we use the first time interval from the one generated by the constructor PDMPProblem
	δt = problem.simjptimes.tstop_extended

	# Main loop
	while (t < tf) && (nsteps < n_jumps)

		verbose && println("--> t = ", t," - δt = ", δt, ",nstep =  ", nsteps)

		res_ode .= Flow(X_extended, Xd, δt, rate)

		verbose && println("--> ode solve is done!")

		# this holds the new state of the continuous component
		@inbounds for ii in eachindex(X_extended)
			X_extended[ii] = res_ode[end, ii]
		end

		# this is the next jump time
		t = res_ode[end, end]

		problem.caract.R(rate, X_extended, Xd, problem.caract.parms, t, false)

		# jump time:
		if (t < tf) && nsteps < n_jumps
			# Update event
			ev = pfsample(rate, sum(rate), numpf)

			# we perform the jump
			affect!(problem.caract.pdmpjump, ev, X_extended, Xd, problem.caract.parms, t)

			verbose && println("--> Which reaction? => ", ev)
			verbose && println("--> xd = ", Xd)

			# save state, post-jump
			push!(t_hist, t)
			push!(xc_hist, X_extended[ind_save_c])
			push!(xd_hist, Xd[ind_save_d])

			save_rate && push!(rate_hist, problem.caract.R(rate, X_extended, Xd, problem.caract.parms, t, true)[1])

			δt = - log(rand())

		else
			if ode in [:cvode, :bdf, :adams]
				res_ode_last = Sundials.cvode((tt, x, xdot)->problem.caract.F(xdot,x,Xd,problem.caract.parms,tt), xc_hist[end], [t_hist[end], tf], abstol = 1e-9, reltol = 1e-7)
			else#if ode==:lsoda
				res_ode_last = LSODA.lsoda((tt, x, xdot, data)->problem.caract.F(xdot,x,Xd,problem.caract.parms,tt), xc_hist[end], [t_hist[end], tf], abstol = 1e-9, reltol = 1e-7)
			end
			t = tf

			# save state
			push!(t_hist, tf)
			push!(xc_hist, res_ode_last[end,ind_save_c])
			push!(xd_hist, Xd[ind_save_d])
		end
		nsteps += 1
	end
	verbose && println("-->Done")
	verbose && println("--> xc = ", xd_hist[:,1:nsteps-1])
	return PDMPResult(t_hist, xc_hist, xd_hist, rate_hist, save_positions)
end
