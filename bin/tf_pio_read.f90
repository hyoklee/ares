! SCORPIO read driver for Terra Fusion data.
!
!   SCORPIO v2.0.3 -> netcdf-fortran 4.6.5 -> netcdf-c 4.10.2 -> HDF5 2.3.0 -> MPICH 4.1.1
!
! Reads a real Terra Fusion variable through the PIO decomposition path
! (PIO_initdecomp + PIO_read_darray) so SCORPIO's iotypes can be compared
! against the raw netcdf-fortran baseline measured by tf_sweep.
!
! NOTE ON THE INPUT FILE: SCORPIO has no netCDF-4 group API — PIOc_inq_varid
! calls nc_inq_varid(file->fh, ...) on the ROOT ncid only (pio_nc.cpp:1781).
! Terra Fusion keeps every science variable inside nested groups, so SCORPIO
! cannot address them in the original granule. This driver therefore reads
! tf_flat.nc, where the variables were copied to root with chunking and
! zlib level preserved bit-for-bit. Chunk layout and filters — the properties
! that govern I/O — are unchanged; only the group nesting is gone.
!
! Usage:  mpiexec -n <N> ./pio_read <netcdf4p|netcdf4c> <modis_ev|aster_swir>

program pio_read
  use pio
  use mpi
  implicit none

  character(len=*), parameter :: FNAME_DEF = '/mnt/common/hyoklee/bench/tf_flat.nc'
  character(len=256) :: FNAME

  type(iosystem_desc_t) :: iosys
  type(file_desc_t)     :: pfile
  type(io_desc_t)       :: iodesc
  type(var_desc_t)      :: vdesc

  character(len=32)  :: iotype_arg, varname
  character(len=256) :: filearg
  integer :: ierr, rank, nprocs, iotype, vid
  integer :: gdims(3), ndims
  integer :: dimid(3), i
  integer(kind=PIO_OFFSET_KIND), allocatable :: compdof(:)
  real(kind=4), allocatable :: buf(:)
  integer(kind=8) :: nslice, i0, i1, ntot
  integer :: nlast, blk, k0, k1, nk
  double precision :: t0, t1, elapsed, mib, agg

  call MPI_Init(ierr)
  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)
  call MPI_Comm_size(MPI_COMM_WORLD, nprocs, ierr)

  call get_command_argument(1, iotype_arg)
  call get_command_argument(2, varname)
  call get_command_argument(3, filearg)
  if (len_trim(varname) == 0) varname = 'modis_ev'
  if (len_trim(filearg) > 0) then
     FNAME = filearg
  else
     FNAME = FNAME_DEF
  end if

  select case (trim(iotype_arg))
  case ('netcdf4p'); iotype = PIO_iotype_netcdf4p
  case ('netcdf4c'); iotype = PIO_iotype_netcdf4c
  case default
     if (rank == 0) print *, 'usage: pio_read <netcdf4p|netcdf4c> <var>'
     call MPI_Abort(MPI_COMM_WORLD, 1, ierr)
  end select

  ! all tasks participate in I/O, stride 1, subset rearranger
  call PIO_init(rank, MPI_COMM_WORLD, nprocs, 1, 1, PIO_rearr_subset, iosys, base=0)

  ierr = PIO_openfile(iosys, pfile, iotype, trim(FNAME), PIO_nowrite)
  if (ierr /= PIO_NOERR) call die('PIO_openfile', ierr)

  ierr = PIO_inq_varid(pfile, trim(varname), vid)
  if (ierr /= PIO_NOERR) call die('PIO_inq_varid '//trim(varname), ierr)
  vdesc%varID = vid
  vdesc%ncid  = pfile%fh

  ierr = PIO_inq_varndims(pfile, vid, ndims)
  if (ierr /= PIO_NOERR) call die('inq_varndims', ierr)
  ierr = PIO_inq_vardimid(pfile, vid, dimid(1:ndims))
  if (ierr /= PIO_NOERR) call die('inq_vardimid', ierr)

  ! SCORPIO's Fortran PIO_inq_vardimid already returns dimids in Fortran
  ! (column-major) order, so take them as-is — reversing here would hand
  ! PIO_initdecomp the C-order shape and blow the dimension bounds.
  do i = 1, ndims
     ierr = PIO_inq_dimlen(pfile, dimid(i), gdims(i))
     if (ierr /= PIO_NOERR) call die('inq_dimlen', ierr)
  end do

  if (rank == 0) then
     print '(a,a,a,a)', '# file=', trim(FNAME), '  var=', trim(varname)
     if (ndims == 3) then
        print '(a,i0,a,i0,a,i0)', '#   gdims (Fortran order) = ', &
             gdims(1), ' x ', gdims(2), ' x ', gdims(3)
     else
        print '(a,i0,a,i0)', '#   gdims (Fortran order) = ', gdims(1), ' x ', gdims(2)
     end if
  end if

  ! decompose over the slowest-varying (last, Fortran) dimension,
  ! matching the tf_sweep decomposition so the numbers are comparable
  nlast  = gdims(ndims)
  nslice = 1
  do i = 1, ndims - 1
     nslice = nslice * int(gdims(i), kind=8)
  end do

  blk = (nlast + nprocs - 1) / nprocs
  k0  = rank * blk + 1
  k1  = min(k0 + blk - 1, nlast)
  nk  = max(k1 - k0 + 1, 0)

  ntot = nslice * int(nk, kind=8)
  allocate(compdof(max(ntot, 1_8)))
  i0 = (int(k0, kind=8) - 1_8) * nslice + 1_8
  do i1 = 1_8, ntot
     compdof(i1) = i0 + i1 - 1_8          ! contiguous global linear indices
  end do
  if (ntot == 0) compdof(1) = 0           ! rank owns nothing

  call PIO_initdecomp(iosys, PIO_real, gdims(1:ndims), &
                      compdof(1:max(ntot,1_8)), iodesc)

  allocate(buf(max(ntot, 1_8)))

  call MPI_Barrier(MPI_COMM_WORLD, ierr)
  t0 = MPI_Wtime()
  call PIO_read_darray(pfile, vdesc, iodesc, buf, ierr)
  if (ierr /= PIO_NOERR) call die('PIO_read_darray', ierr)
  call MPI_Barrier(MPI_COMM_WORLD, ierr)
  t1 = MPI_Wtime()

  elapsed = t1 - t0
  mib = real(ntot, kind=8) * 4.0d0 / 1048576.0d0
  call MPI_Reduce(mib, agg, 1, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)

  if (rank == 0) then
     print '(a,a,a,i0,a,f10.2,a,f9.4,a,f10.1)', &
          trim(varname), ',', trim(iotype_arg)//',', nprocs, ',', agg, ',', &
          elapsed, ',', agg / max(elapsed, 1.0d-9)
  end if

  call PIO_freedecomp(iosys, iodesc)
  call PIO_closefile(pfile)
  call PIO_finalize(iosys, ierr)
  call MPI_Finalize(ierr)

contains
  subroutine die(what, code)
    character(len=*), intent(in) :: what
    integer, intent(in) :: code
    print '(a,a,a,i0)', 'FAIL [', what, ']: PIO error ', code
    call MPI_Abort(MPI_COMM_WORLD, 1, ierr)
  end subroutine die
end program pio_read
