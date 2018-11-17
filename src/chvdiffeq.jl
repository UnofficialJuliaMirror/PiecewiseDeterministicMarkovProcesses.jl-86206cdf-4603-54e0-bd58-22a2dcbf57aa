###################################################################################################
###################################################################################################
###################################################################################################
### implementation of the CHV algo using DiffEq

# callable struct
function (prob::PDMPProblem)(u,t,integrator)
    (t == prob.sim.tstop_extended)
end

# The following function is a callback to discrete jump. Its role is to perform the jump on the solution given by the ODE solver
# callable struct
function (prob::PDMPProblem)(integrator)
	prob.verbose && printstyled(color=:green,"--> Jump detected!!\n")
	# find the next jump time
	t = integrator.u[end]

	# state of the continuous variable right before the jump
# HOW TO USE VIEW FOR THIS?
	X0 = @view integrator.u[1:end-1]
	prob.verbose && printstyled(color=:green,"--> jump not yet performed, xd = ",prob.xd,"\n")

	if (prob.save_pre_jump) && (t <= prob.tf)
		prob.verbose && printstyled(color=:green,"----> save pre-jump\n")
		push!(prob.Xc,integrator.u[1:end-1])
		push!(prob.Xd,copy(prob.xd))
		push!(prob.time,t)
	end

	# execute the jump
	prob.pdmpFunc.R(prob.rate,X0,prob.xd,t,prob.parms, false)
	if (t < prob.tf)
		# Update event
		ev = pfsample(prob.rate,sum(prob.rate),length(prob.rate))

		deltaxd = view(prob.nu,ev,:)

		# Xd = Xd .+ deltaxd
		LinearAlgebra.BLAS.axpy!(1.0, deltaxd, prob.xd)

		# Xc = Xc .+ deltaxc
		prob.pdmpFunc.Delta(X0,prob.xd,t,prob.parms,ev)
	end
	prob.verbose && printstyled(color=:green,"--> jump effectued, xd = ",prob.xd,"\n")
	# we register the next time interval to solve ode
	prob.sim.njumps += 1
	prob.sim.tstop_extended += -log(rand())
	add_tstop!(integrator, prob.sim.tstop_extended)
	prob.verbose && printstyled(color=:green,"--> End jump\n\n")
end

# callable struct
function (prob::PDMPProblem{Tc,Td,vectype_xc,vectype_xd,Tnu,Tp,TF,TR,TD})(xdot::vectype_xc,x::vectype_xc,data,t::Tc) where {Tc,Td,vectype_xc<:AbstractVector{Tc},vectype_xd<:AbstractVector{Td},Tnu<:AbstractArray{Td},Tp,TF,TR,TD}
	# used for the exact method
	# we put [1] to use it in the case of the rejection method as well
	tau = x[end]
	sr = prob.pdmpFunc.R(prob.rate,x,prob.xd,tau,prob.parms,true)[1]
	@assert(sr > 0.0, "Total rate must be positive")
	prob.pdmpFunc.F(xdot,x,prob.xd,tau,prob.parms)
	xdot[end] = 1
	@inbounds for i in eachindex(xdot)
		xdot[i] = xdot[i] / sr
	end
	nothing
end

"""
Implementation of the CHV method to sample a PDMP using the package `DifferentialEquations`. The advantage of doing so is to lower the number of calls to `solve` using an `integrator` method.
"""
function chv_diffeq!(xc0,xd0,
				F::Tf,R::Tr,DX::Td,
				nu::Tnu,parms::Tp,
				ti::Float64, tf::Float64,
				verbose::Bool = false;
				ode = Tsit5(),ind_save_d=-1:1,ind_save_c=-1:1,save_positions=(false,true),n_jumps::Int64 = Inf64) where {Tnu <: AbstractArray{Int64}, Tp, Tf ,Tr ,Td }

				# custom type to collect all parameters in one structure
				problem  = PDMPProblem{eltype(xc0),eltype(xd0),typeof(xc0),typeof(xd0),Tnu,Tp,Tf,Tr,Td}(xc0,xd0,F,R,DX,nu,parms,ti,tf,save_positions[1],verbose)

				chv_diffeq!(problem,ti,tf;ode = ode,ind_save_c = ind_save_c, ind_save_d = ind_save_d, save_positions = save_positions,n_jumps = n_jumps)
end

function chv_diffeq!(problem::PDMPProblem{Tc,Td,vectype_xc,vectype_xd,Tnu,Tp,TF,TR,TD},ti::Tc,tf::Tc, verbose = false;ode=Tsit5(),ind_save_d = -1:1,ind_save_c = -1:1,save_positions=(false,true),n_jumps::Td = Inf64) where {Tc,Td,vectype_xc<:AbstractVector{Tc},vectype_xd<:AbstractVector{Td},Tnu<:AbstractArray{Td},Tp,TF,TR,TD}
	problem.verbose && printstyled(color=:red,"Entry in chv_diffeq\n")
	t = ti

	# vector to hold the state space for the extended system
	X_extended = copy(problem.xc); push!(X_extended,ti)

	# definition of the callback structure passed to DiffEq
	cb = DiscreteCallback(problem, problem, save_positions = (false,false))

	xdot0 = copy(problem.xc)
	xc0 = copy(problem.xc);push!(xc0,0.)

	# define the ODE flow, this leads to big memory saving
	prob_CHV = ODEProblem((xdot,x,data,tt)->problem(xdot,x,data,tt),X_extended,(ti,tf))
	integrator = init(prob_CHV, ode, tstops = problem.sim.tstop_extended, callback=cb, save_everystep = false,reltol=1e-8,abstol=1e-8,advance_to_tstop=true)
	njumps = 0
# I DONT NEED TO TAKE CARE OF THE FACT THAT the last jump might be after tf
	while (t < tf) && problem.sim.njumps < n_jumps-1
		problem.verbose && println("--> n = $(problem.njumps), t = $t")
		step!(integrator)
		t = integrator.u[end]
		# the previous step was a jump!
		if njumps < problem.sim.njumps && save_positions[2] && (t <= problem.tf)
			problem.verbose && println("----> save post-jump, xd = ",problem.Xd)
			# need to find a good way to solve the jumps, not done YET
			push!(problem.Xc,integrator.u[1:end-1])
			push!(problem.Xd,copy(problem.xd))
			push!(problem.time,t)
			njumps +=1
			problem.verbose && println("----> end save post-jump, ")
		end
	end
	# we check that the last bit [t_last_jump, tf] is not missing
	if t>tf
		problem.verbose && println("----> LAST BIT!!, xc = ",problem.Xc[end], ", xd = ",problem.xd)
		prob_last_bit = ODEProblem((xdot,x,data,tt)->problem.F(xdot,x,problem.xd,tt,problem.parms),
					problem.Xc[end],(problem.time[end],tf))
		sol = solve(prob_last_bit, ode)
		push!(problem.Xc,sol.u[end])
		push!(problem.Xd,copy(problem.xd))
		push!(problem.time,sol.t[end])
	end
	return PDMPResult(problem.time,problem.Xc,problem.Xd)
end
