! Terra Fusion parallel netCDF-4 read benchmark.
!
! Stack: netcdf-fortran 4.6.5 -> netcdf-c 4.10.2 -> HDF5 2.3.0 (parallel) -> MPICH 4.1.1
!
! Usage:  mpiexec -n <N> ./tf_sweep <key> <coll|indep>
!
! Each rank reads a contiguous block along the slowest-varying dimension.
! The four keys span the chunk regimes present in a Basic Fusion granule:
!   mopitt : contiguous, UNCOMPRESSED          (baseline, no inflate)
!   modis  : {1,2030,1354} x 16 chunks, zlib-1 (decomposes 16 ways)
!   aster  : single 32 MB chunk, zlib-1        (cannot decompose)
!   misr   : single 755 MB chunk, zlib-1       (pathological)
!
! Emits one CSV line from rank 0:  key,mode,nprocs,MiB,seconds,MiB_s

program tf_sweep
  use netcdf
  use mpi
  implicit none

  character(len=*), parameter :: PATH = &
    '/mnt/common/datasets-staging/TERRA_BF_L1B_O10204_20011118010522_F000_V001.h5'
  character(len=*), parameter :: FLAT = '/mnt/common/hyoklee/bench/tf_flat.nc'

  character(len=32)  :: key, mode
  character(len=256) :: filearg
  character(len=256) :: gpath, vname
  integer :: ierr, rank, nprocs, ncid, gid, varid, vndims, i
  integer :: dimids(4), dims(4)
  integer :: start(4), cnt(4)
  integer :: nlast, blk, s_last, c_last, access_flag, st
  integer(kind=8) :: nelem
  real, allocatable :: buf1(:), buf2(:,:), buf3(:,:,:)
  double precision :: t0, t1, elapsed, mib, agg_mib
  double precision :: my_bytes

  call MPI_Init(ierr)
  call MPI_Comm_rank(MPI_COMM_WORLD, rank, ierr)
  call MPI_Comm_size(MPI_COMM_WORLD, nprocs, ierr)

  call get_command_argument(1, key)
  call get_command_argument(2, mode)
  call get_command_argument(3, filearg)

  select case (trim(key))
  case ('mopitt')
     gpath = 'MOPITT/granule_20011118/Geolocation';                vname = 'Latitude'
  case ('modis')
     gpath = 'MODIS/granule_2001322_0110/_1KM/Data_Fields';        vname = 'EV_1KM_Emissive'
  case ('aster')
     gpath = 'ASTER/granule_11182001013943/SWIR';                  vname = 'ImageData4'
  case ('misr')
     gpath = 'MISR/AN/Data_Fields';                                vname = 'Red_Radiance'
  case ('flat_modis')
     gpath = '';                                                  vname = 'modis_ev'
  case ('flat_aster')
     gpath = '';                                                  vname = 'aster_swir'
  case ('flat_misr')
     gpath = '';                                                  vname = 'misr_red'
  case default
     if (rank == 0) print *, 'unknown key: ', trim(key)
     call MPI_Abort(MPI_COMM_WORLD, 1, ierr)
  end select

  if (len_trim(gpath) == 0) then
     ! root-level variable in a flattened file; arg 3 overrides the default path
     if (len_trim(filearg) > 0) then
        call chk(nf90_open_par(trim(filearg), NF90_NOWRITE, MPI_COMM_WORLD, MPI_INFO_NULL, ncid), 'open_par')
     else
        call chk(nf90_open_par(FLAT, NF90_NOWRITE, MPI_COMM_WORLD, MPI_INFO_NULL, ncid), 'open_par')
     end if
     gid = ncid
  else
     call chk(nf90_open_par(PATH, NF90_NOWRITE, MPI_COMM_WORLD, MPI_INFO_NULL, ncid), 'open_par')
     call walk_groups(ncid, trim(gpath), gid)
  end if
  call chk(nf90_inq_varid(gid, trim(vname), varid), 'inq_varid '//trim(vname))
  call chk(nf90_inquire_variable(gid, varid, ndims=vndims, dimids=dimids), 'inq_var')
  do i = 1, vndims
     call chk(nf90_inquire_dimension(gid, dimids(i), len=dims(i)), 'inq_dim')
  end do

  ! access mode (independent is the fallback if collective is refused)
  if (trim(mode) == 'coll') then
     access_flag = NF90_COLLECTIVE
  else
     access_flag = NF90_INDEPENDENT
  end if
  st = nf90_var_par_access(gid, varid, access_flag)
  if (st /= NF90_NOERR) then
     if (rank == 0) print '(a,a,a)', '# ', trim(key), ': par_access REFUSED -> falling back'
     call chk(nf90_var_par_access(gid, varid, NF90_INDEPENDENT), 'par_access fallback')
  end if

  ! decompose over the slowest-varying (last, in Fortran order) dimension
  nlast  = dims(vndims)
  blk    = (nlast + nprocs - 1) / nprocs
  s_last = rank * blk + 1
  c_last = min(blk, nlast - s_last + 1)
  if (c_last < 0) c_last = 0

  start = 1
  cnt   = 1
  do i = 1, vndims - 1
     cnt(i) = dims(i)
  end do
  start(vndims) = max(s_last, 1)
  cnt(vndims)   = c_last

  nelem = 1
  do i = 1, vndims
     nelem = nelem * int(cnt(i), kind=8)
  end do
  my_bytes = real(nelem, kind=8) * 4.0d0

  call MPI_Barrier(MPI_COMM_WORLD, ierr)
  t0 = MPI_Wtime()
  if (c_last > 0) then
     select case (vndims)
     case (1)
        allocate(buf1(cnt(1)))
        call chk(nf90_get_var(gid, varid, buf1, start=start(1:1), count=cnt(1:1)), 'get_var1')
        deallocate(buf1)
     case (2)
        allocate(buf2(cnt(1), cnt(2)))
        call chk(nf90_get_var(gid, varid, buf2, start=start(1:2), count=cnt(1:2)), 'get_var2')
        deallocate(buf2)
     case (3)
        allocate(buf3(cnt(1), cnt(2), cnt(3)))
        call chk(nf90_get_var(gid, varid, buf3, start=start(1:3), count=cnt(1:3)), 'get_var3')
        deallocate(buf3)
     end select
  end if
  call MPI_Barrier(MPI_COMM_WORLD, ierr)
  t1 = MPI_Wtime()

  elapsed = t1 - t0
  mib = my_bytes / 1048576.0d0
  call MPI_Reduce(mib, agg_mib, 1, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)

  if (rank == 0) then
     print '(a,a,a,a,a,i0,a,f10.2,a,f9.4,a,f10.1)', &
          trim(key), ',', trim(mode), ',', '', nprocs, ',', agg_mib, ',', elapsed, ',', &
          agg_mib / max(elapsed, 1.0d-9)
  end if

  call chk(nf90_close(ncid), 'close')
  call MPI_Finalize(ierr)

contains

  ! descend a '/'-separated group path from ncid
  subroutine walk_groups(root, p, leaf)
    integer, intent(in) :: root
    character(len=*), intent(in) :: p
    integer, intent(out) :: leaf
    integer :: cur, nxt, ib, ie
    cur = root
    ib = 1
    do
       ie = index(p(ib:), '/')
       if (ie == 0) then
          call chk(nf90_inq_ncid(cur, p(ib:), nxt), 'grp '//p(ib:))
          cur = nxt
          exit
       else
          call chk(nf90_inq_ncid(cur, p(ib:ib+ie-2), nxt), 'grp '//p(ib:ib+ie-2))
          cur = nxt
          ib = ib + ie
       end if
    end do
    leaf = cur
  end subroutine walk_groups

  subroutine chk(status, what)
    integer, intent(in) :: status
    character(len=*), intent(in) :: what
    if (status /= NF90_NOERR) then
       print '(a,a,a,a)', 'FAIL [', what, ']: ', trim(nf90_strerror(status))
       call MPI_Abort(MPI_COMM_WORLD, 1, ierr)
    end if
  end subroutine chk

end program tf_sweep
