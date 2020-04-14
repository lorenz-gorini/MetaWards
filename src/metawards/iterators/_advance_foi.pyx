#!/bin/env/python3
#cython: linetrace=False
# MUST ALWAYS DISABLE AS WAY TOO SLOW FOR ITERATE

cimport cython
from cython.parallel import parallel, prange
cimport openmp

from libc.stdlib cimport malloc, free
from libc.math cimport cos, pi

from .._network import Network
from ..utils._profiler import Profiler

from ..utils._ran_binomial cimport _ran_binomial, \
                                   _get_binomial_ptr, binomial_rng

from ..utils._get_array_ptr cimport get_int_array_ptr, get_double_array_ptr

__all__ = ["advance_foi", "advance_foi_omp"]


cdef struct foi_buffer:
    int count
    int *index
    double *foi


cdef foi_buffer* allocate_foi_buffers(int nthreads,
                                      int buffer_size=4096) nogil:
    cdef int size = buffer_size
    cdef int n = nthreads

    cdef foi_buffer *buffers = <foi_buffer *> malloc(n * sizeof(foi_buffer))

    for i in range(0, nthreads):
        buffers[i].count = 0
        buffers[i].index = <int *> malloc(size * sizeof(int))
        buffers[i].foi = <double *> malloc(size * sizeof(double))

    return buffers


cdef void free_foi_buffers(foi_buffer *buffers, int nthreads) nogil:
    cdef int n = nthreads

    for i in range(0, nthreads):
        free(buffers[i].index)
        free(buffers[i].foi)

    free(buffers)


cdef void add_from_buffer(foi_buffer *buffer, double *wards_foi) nogil:
    cdef int i = 0
    cdef int count = buffer[0].count

    for i in range(0, count):
        wards_foi[buffer[0].index[i]] += buffer[0].foi[i]


cdef inline void add_to_buffer(foi_buffer *buffer, int index, double value,
                               double *wards_foi,
                               openmp.omp_lock_t *lock,
                               int buffer_size=4096) nogil:
    cdef int count = buffer[0].count

    buffer[0].index[count] = index
    buffer[0].foi[count] = value
    buffer[0].count = count + 1

    if buffer[0].count >= buffer_size:
        openmp.omp_set_lock(lock)
        add_from_buffer(buffer, wards_foi)
        openmp.omp_unset_lock(lock)
        buffer[0].count = 0


def advance_foi_omp(network: Network, infections, play_infections, rngs,
                    nthreads: int, day: int, profiler: Profiler, **kwargs):
    """Advance the model calculating the new force of infection (foi)
       for all of the wards and links between wards, based on the
       current number of infections. Note that you must call this
       first before performing any other step in the iteration
       as this will update the foi based on the infections that
       occured the previous day. This is the parallel version of
       this function

       Parameters
       ----------
       network: Network
         The network being modelled
       infections:
         The space that holds all of the "work" infections
       play_infections:
         The space that holds all of the "play" infections
       rngs:
         The list of thread-safe random number generators, one per thread
       nthreads: int
         The number of threads over which to parallelise the calculation
       day: int
         The day of the outbreak (timestep in the simulation)
       profiler: Profiler
         The profiler used to profile this calculation
       kwargs:
         Extra arguments that may be used by other advancers, but which
         are not used by advance_play
    """

    links = network.to_links
    wards = network.nodes
    plinks = network.play
    params = network.params

    cdef double uv = params.UV
    cdef int ts = day
    cdef double uvscale = (1.0-uv/2.0 + cos(2.0*pi*ts/365.0)/2.0)

    # Copy arguments from Python into C cdef variables
    cdef double * wards_day_foi = get_double_array_ptr(wards.day_foi)
    cdef double * wards_night_foi = get_double_array_ptr(wards.night_foi)

    cdef double * links_weight = get_double_array_ptr(links.weight)
    cdef double * plinks_weight = get_double_array_ptr(plinks.weight)

    cdef int * links_ifrom = get_int_array_ptr(links.ifrom)
    cdef int * links_ito = get_int_array_ptr(links.ito)

    cdef int * plinks_ifrom = get_int_array_ptr(plinks.ifrom)
    cdef int * plinks_ito = get_int_array_ptr(plinks.ito)

    cdef int * wards_begin_p = get_int_array_ptr(wards.begin_p)
    cdef int * wards_end_p = get_int_array_ptr(wards.end_p)

    cdef double * links_distance = get_double_array_ptr(links.distance)
    cdef double * plinks_distance = get_double_array_ptr(plinks.distance)

    cdef double cutoff = params.dyn_dist_cutoff

    # get the random number generator
    cdef unsigned long [::1] rngs_view = rngs
    cdef binomial_rng* rng   # pointer to parallel rng

    # create and initialise variables used in the loop
    cdef int num_threads = nthreads
    cdef int thread_id = 0

    cdef int nnodes_plus_one = network.nnodes + 1
    cdef int nlinks_plus_one = network.nlinks + 1

    cdef int i = 0
    cdef int j = 0
    cdef int k = 0
    cdef int end_p = 0
    cdef int inf_ij = 0
    cdef int ifrom = 0
    cdef int ito = 0
    cdef int staying = 0
    cdef int moving = 0
    cdef int play_move = 0

    cdef int N_INF_CLASSES = len(infections)

    cdef double weight = 0.0
    cdef double cumulative_prob = 0.0
    cdef double prob_scaled = 0.0
    cdef double too_ill_to_move = 0.0
    cdef double scl_foi_uv = 0.0

    # allocate buffers that will be used to manage the reductions
    cdef foi_buffer * day_buffers = allocate_foi_buffers(num_threads)
    cdef foi_buffer * day_buffer
    cdef foi_buffer * night_buffers = allocate_foi_buffers(num_threads)
    cdef foi_buffer * night_buffer

    # we need to create an OpenMP lock so that we can
    # use critical regions to serialise reduction updates
    cdef openmp.omp_lock_t lock
    openmp.omp_init_lock(&lock)

    ## Finally(!) we can now declare the actual loop.
    ## This loops over all disease stages, and then in
    ## parallel over all wards and all links to then
    ## update the daytime and nighttime foi arrays
    ## for each ward (wards.day_foi and wards.night_foi)

    ## we begin by initialising the day and night fois to 0
    p = profiler.start("setup")
    for i in range(1, network.nnodes+1):
        wards_day_foi[i] = 0.0
        wards_night_foi[i] = 0.0
    p = p.stop()

    p = p.start("loop_over_classes")
    for i in range(0, N_INF_CLASSES):
        contrib_foi = params.disease_params.contrib_foi[i]
        beta = params.disease_params.beta[i]
        scl_foi_uv = contrib_foi * beta * uvscale
        too_ill_to_move = params.disease_params.too_ill_to_move[i]

        # number of people staying gets bigger as
        # PlayAtHome increases
        play_at_home_scl = <double>(params.dyn_play_at_home *
                                    too_ill_to_move)

        infections_i = get_int_array_ptr(infections[i])
        play_infections_i = get_int_array_ptr(play_infections[i])

        if contrib_foi > 0:
            p = p.start(f"work_{i}")
            with nogil, parallel(num_threads=1):
                thread_id = cython.parallel.threadid()
                rng = _get_binomial_ptr(rngs_view[thread_id])
                day_buffer = &(day_buffers[thread_id])
                night_buffer = &(night_buffers[thread_id])
                day_buffer[0].count = 0
                night_buffer[0].count = 0

                for j in prange(1, nlinks_plus_one, schedule="static"):
                    # deterministic movements (e.g. to work)
                    inf_ij = infections_i[j]
                    if inf_ij > 0:
                        weight = links_weight[j]
                        ifrom = links_ifrom[j]
                        ito = links_ito[j]

                        #if inf_ij > weight:
                        #    print(f"inf[{i}][{j}] {inf_ij} > links[j].weight "
                        #        f"{weight}")

                        if links_distance[j] < cutoff:
                            # number staying - this is G_ij
                            staying = _ran_binomial(rng,
                                                    too_ill_to_move,
                                                    inf_ij)

                            # number moving, this is I_ij - G_ij
                            moving = inf_ij - staying

                            if staying > 0:
                                add_to_buffer(day_buffer, ifrom,
                                              staying * scl_foi_uv,
                                              &(wards_day_foi[0]), &lock)
                            #wards_day_foi[ifrom] += staying * scl_foi_uv

                            # Daytime Force of
                            # Infection is proportional to
                            # number of people staying
                            # in the ward (too ill to work)
                            # this is the sum for all G_ij (including g_ii
                            if moving > 0:
                                add_to_buffer(day_buffer, ito,
                                              moving * scl_foi_uv,
                                              &(wards_day_foi[0]), &lock)
                            #wards_day_foi[ito] += moving * scl_foi_uv

                            # Daytime FOI for destination is incremented
                            # (including self links, I_ii)
                        else:
                            # outside cutoff
                            if inf_ij > 0:
                                add_to_buffer(day_buffer, ifrom,
                                              inf_ij * scl_foi_uv,
                                              &(wards_day_foi[0]), &lock)
                            #wards_day_foi[ifrom] += inf_ij * scl_foi_uv

                        if inf_ij > 0:
                            add_to_buffer(night_buffer, ifrom,
                                          inf_ij * scl_foi_uv,
                                          &(wards_night_foi[0]), &lock)
                        #wards_night_foi[ifrom] += inf_ij * scl_foi_uv

                        # Nighttime Force of Infection is
                        # prop. to the number of Infected individuals
                        # in the ward
                        # This I_ii in Lambda^N

                    # end of if inf_ij (are there any new infections)
                # end of infectious class loop

                openmp.omp_set_lock(&lock)
                add_from_buffer(day_buffer, &(wards_day_foi[0]))
                add_from_buffer(night_buffer, &(wards_night_foi[0]))
                openmp.omp_unset_lock(&lock)
            # end of parallel section
            p = p.stop()

            p = p.start(f"play_{i}")
            with nogil, parallel(num_threads=1):
                thread_id = cython.parallel.threadid()
                rng = _get_binomial_ptr(rngs_view[thread_id])
                day_buffer = &(day_buffers[thread_id])
                day_buffer[0].count = 0

                for j in prange(1, nnodes_plus_one, schedule="static"):
                    # playmatrix loop FOI loop (random/unpredictable movements)
                    inf_ij = play_infections_i[j]
                    if inf_ij > 0:
                        wards_night_foi[j] += inf_ij * scl_foi_uv

                        staying = _ran_binomial(rng, play_at_home_scl, inf_ij)
                        moving = inf_ij - staying

                        cumulative_prob = 0.0
                        k = wards_begin_p[j]

                        end_p = wards_end_p[j]

                        while (moving > 0) and (k < end_p):
                            # distributing people across play wards
                            if plinks_distance[k] < cutoff:
                                weight = plinks_weight[k]
                                ifrom = plinks_ifrom[k]
                                ito = plinks_ito[k]

                                prob_scaled = weight / (1.0 - cumulative_prob)
                                cumulative_prob = cumulative_prob + weight

                                play_move = _ran_binomial(rng, prob_scaled,
                                                          moving)

                                add_to_buffer(day_buffer, ito,
                                                play_move * scl_foi_uv,
                                                &(wards_day_foi[0]),
                                                &lock)
                                #wards_day_foi[ito] += play_move * scl_foi_uv

                                moving = moving - play_move
                            # end of if within cutoff

                            k = k + 1
                        # end of while loop

                        wards_day_foi[j] += (moving + staying) * scl_foi_uv
                    # end of if inf_ij (there are new infections)

                # end of loop over all nodes
                openmp.omp_set_lock(&lock)
                add_from_buffer(day_buffer, &(wards_day_foi[0]))
                openmp.omp_unset_lock(&lock)
            # end of parallel
            p = p.stop()
        # end of params.disease_params.contrib_foi[i] > 0:
    p = p.stop()
    # end of loop over all disease classes

    free_foi_buffers(&(day_buffers[0]), num_threads)
    free_foi_buffers(&(night_buffers[0]), num_threads)


def advance_foi(network: Network, infections, play_infections, rngs,
                day: int, profiler: Profiler, **kwargs):
    """Advance the model calculating the new force of infection (foi)
       for all of the wards and links between wards, based on the
       current number of infections. Note that you must call this
       first before performing any other step in the iteration
       as this will update the foi based on the infections that
       occured the previous day. This is the serial version of
       this function

       Parameters
       ----------
       network: Network
         The network being modelled
       infections:
         The space that holds all of the "work" infections
       play_infections:
         The space that holds all of the "play" infections
       rngs:
         The list of thread-safe random number generators, one per thread
       day: int
         The day of the outbreak (timestep in the simulation)
       profiler: Profiler
         The profiler used to profile this calculation
       kwargs:
         Extra arguments that may be used by other advancers, but which
         are not used by advance_play
    """
    advance_foi_omp(network=network, infections=infections,
                    play_infections=play_infections, rngs=rngs,
                    day=day, profiler=profiler, **kwargs)
